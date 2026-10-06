
# Table of Contents

1.  [How to use this file](#org97668aa)
    1.  [Where does the output go?](#org897f433)
    2.  [Why the samples are subtrees](#orgefbd59a)
    3.  [Keys in this file](#org15303e2)
2.  [The export dispatcher](#org4dafb16)
    1.  [Sample: first export](#orgc8c3ec6)
        1.  [A child heading](#orgd81a00d)
    2.  [Exercises: first export](#org3ec8003)
    3.  [Visible only](#org302e170)
    4.  [Sample: visible only](#orgc0d11a5)
        1.  [Section one](#org80a4529)
        2.  [Section two](#orgfee8a47)
    5.  [Exercises: visible only](#org26715ee)
    6.  [Async](#org29e3bf9)
    7.  [The settings template (`#`)](#orgd5b1c41)
        1.  [Scratch heading for the template](#org6d2fcfd)
3.  [Back-ends and the tools they need](#orgd279195)
4.  [Document keywords: title, author, date, &hellip;](#org3c0e124)
    1.  [Sample: title block](#orgef0656a)
    2.  [Exercises: title block](#org6123cb4)
    3.  [Sample: another language](#orgd782e4f)
        1.  [Première partie](#org7cb858b)
    4.  [Exercises: another language](#org6063be0)
5.  [#+OPTIONS: the export switches](#orgd462ce2)
    1.  [Sample: toc, num and H](#org1040116)
        1.  [Chapter](#org6f725ab)
        2.  [Another chapter](#org439ff3f)
    2.  [Exercises: toc, num and H](#org8f07deb)
    3.  [Sample: sub- and superscripts](#org297da5f)
    4.  [Exercises: sub- and superscripts](#orgaa3a7e6)
    5.  [Sample: tags, TODO keywords and priorities](#org05944c1)
        1.  [Write the report](#orgb6fc2e2):work:
        2.  [Book the room](#org7586be0):office:
        3.  [Plan the offsite <code>[1/2]</code>](#org652c872)
    6.  [Exercises: tags, TODO keywords and priorities](#org4b1d8d6)
    7.  [Sample: drawers, planning, clocks and timestamps](#org6d62026)
        1.  [Ship the release](#orgab33211)
    8.  [Exercises: drawers, planning, clocks and timestamps](#orgcf0df04)
    9.  [Sample: line breaks, quotes, special strings](#org85dfe2e)
    10. [Exercises: line breaks, quotes, special strings](#org8ba8d27)
    11. [Sample: what to leave out entirely](#orga176ef6)
    12. [Exercises: what to leave out entirely](#org6edcd02)
6.  [Choosing what is exported](#orgaaaef3c)
    1.  [Tags: noexport and export](#org6f52acd)
    2.  [Sample: noexport](#org732606e)
        1.  [Kept](#org1af4fa9)
        2.  [Also kept](#org9320ec8)
    3.  [Exercises: noexport](#orgc8654cb)
    4.  [Sample: select tags](#org8de3f27)
        1.  [Chosen](#org05b67b0):keep:
        2.  [Not chosen](#org58c3b7f)
        3.  [Chosen but secret](#org19028c7):keep:secret:
    5.  [Exercises: select tags](#orgd7ba314)
    6.  [Sample: COMMENT headings, comment lines and blocks](#org40ca3d5)
        1.  [Finished part](#org58060d5)
    7.  [Exercises: COMMENT headings, comment lines and blocks](#org9d95138)
    8.  [Sample: archived trees](#orgfc3831a)
        1.  [Current work](#org2f1a4d1)
        2.  [Old project](#org610520a):ARCHIVE:
    9.  [Exercises: archived trees](#orgaeccd88)
7.  [Subtree properties (EXPORT<sub>\*</sub>)](#orgb494fdc)
    1.  [Sample: a subtree is its own document](#orgfb87ab7)
    2.  [Exercises: a subtree is its own document](#orge417ad7)
8.  [Table of contents](#org6669e35)
    1.  [Sample: tables of contents](#orgd093eb4)
        -   [Preface](#org8228d88)
        1.  [Setup](#orgceb5939)
    2.  [Exercises: tables of contents](#orgb6d0386)
9.  [Captions, names and cross-references](#orge018dd6)
    1.  [Sample: cross-references](#org627852b)
        1.  [Data](#data)
        2.  [Discussion](#org301e875)
    2.  [Exercises: cross-references](#org93312df)
10. [Footnotes in export](#orgcf84e55)
    1.  [Sample: footnotes](#org52a16be)
    2.  [Exercises: footnotes](#org5739b0a)
11. [Macros](#org254f1b8)
    1.  [Sample: macros](#orgb33855c)
        1.  [Owned part](#org1fa24c4)
    2.  [Exercises: macros](#org99b8178)
12. [Raw output for one back-end](#orgc1855ad)
    1.  [Sample: snippets and export blocks](#org63a82c9)
    2.  [Exercises: snippets and export blocks](#org3855050)
13. [HTML specifics: #+ATTR<sub>HTML</sub> and #+HTML<sub>HEAD</sub>](#org42d1764)
    1.  [Sample: HTML attributes](#org7e9f4b5)
    2.  [Exercises: HTML attributes](#orgc998d61)
14. [LaTeX and PDF specifics](#org2580b9d)
    1.  [Sample: LaTeX attributes](#org37dc0a3)
    2.  [Exercises: LaTeX attributes](#orgebd05b4)
15. [Beamer slides](#orga657571)
    1.  [Sample: slides](#org8b4ae79)
        1.  [First slide](#orgb998a8e)
        2.  [Two columns](#orgc16cabf)
    2.  [Exercises: slides](#org8d32f2f)
16. [Markdown, GFM, plain text and Org](#org5f1eceb)
    1.  [Sample: a table and code everywhere](#org1153bb5)
    2.  [Exercises: a table and code everywhere](#org8414234)
17. [#+INCLUDE: pulling in other files](#org5b7a29e)
    1.  [Sample: include](#org5060a91)
    2.  [Exercises: include](#org2d522f4)
18. [Source blocks and :exports](#org617150d)
    1.  [Sample: exports](#orgeb4a2da)
    2.  [Exercises: exports](#orgf7db64b)
19. [Citations](#org4554367)
    1.  [Sample: citations](#orgaa5f503)
    2.  [Exercises: citations](#org447f95a)
20. [Broken links](#org0acc137)
    1.  [Sample: broken links](#org72f1af6)
    2.  [Exercises: broken links](#org6730c51)
21. [iCalendar, ODT, DOCX, Texinfo and pandoc (file exports)](#org0373b60)
    1.  [Sample: calendar entries](#org537a46d)
        1.  [Team meeting](#org3a82934)
        2.  [Submit the report](#orgedc1d8f)
    2.  [Exercises: calendar entries](#org9fdb3b0)
22. [Hugo blog posts (the hugo extension)](#orge3c0000)
    1.  [Sample: a Hugo post](#orgdc74bcd):emacs:@notes:
        1.  [A section](#org36bb00b)
    2.  [Exercises: a Hugo post](#orgbda6d3b)
23. [Publishing projects](#org254b633)
24. [Configuring defaults](#org8185bc2)
25. [Further reading](#orgce04e31)



<a id="org97668aa"></a>

# How to use this file

Export turns an Org file (or one subtree of it) into another format: HTML,
LaTeX/PDF, Beamer slides, Markdown, plain text, ODT, iCalendar, Texinfo,
Org, or anything pandoc can write. This file walks through the dispatcher,
every back-end, the export settings and the markup that only matters on
export, with sample subtrees you export yourself and compare with the
output quoted here.

-   The file opens folded (`#+STARTUP: overview`). `<Tab>` on a heading opens
    it, `<S-Tab>` cycles the whole buffer.
-   `u` undoes anything; `git checkout examples/19-export.org` restores the
    file.
-   `g?` lists every key of the current buffer. `<prefix>` is `<leader>o`
    (with the bundled init, `<Space>o`). Emacs keys work too: `C-c C-e` is the
    dispatcher.
-   Lines starting with **Try:** are exercises, **Expect:** says what you should
    see. Lines starting with =# = (hash, space) are comments: they explain
    the examples and are never exported.

Start Neovim from the repo root with the bundled init, which keeps your own
config and notes out of the way:

    nvim -u examples/minimal_init.lua examples/19-export.org

(`examples/minimal_init.lua` sets the agenda files to `examples/*.org`, puts
captures in a scratch directory under `stdpath("state")` and defines a few
capture templates and agenda commands; none of that matters for export.)


<a id="org897f433"></a>

## Where does the output go?

-   **To a buffer** (the capital-letter keys: `h H`, `m M`, `t A`, `t U`,
    `l L`, `l B`, `O O`, `m G`): the result opens in a vertical split, in a
    scratch buffer named like "Org HTML Export #12". Nothing is written to
    disk; close it with `:q`. **All exercises in this file use these keys.**
-   **To a file** (lower-case keys: `h h`, `m m`, `t a`, `l l`, `o o`, &hellip;):
    the file is written **next to this one, inside the repo**
    (`examples/19-export.html` and friends, or `#+EXPORT_FILE_NAME`). Only a
    few exercises do that and they say so; delete the files afterwards
    (`git status` shows them as untracked) or set `export.output_dir` in
    your config to send them elsewhere.


<a id="orgefbd59a"></a>

## Why the samples are subtrees

Almost every exercise exports **one subtree**: put the cursor anywhere inside
a heading called "Sample: &hellip;" and press `<prefix>e s` first (`s` toggles
"export scope = subtree"), then the back-end keys. A subtree export:

-   uses only the body of that heading: its children become the top-level
    sections of the output, and the heading itself is not a section;
-   reads `EXPORT_*` properties from the heading's `:PROPERTIES:` drawer
    (`EXPORT_TITLE`, `EXPORT_OPTIONS`, &hellip;). They override the `#+...`
    keywords of the file, so every sample carries its own settings.

**Important:** `#+TITLE:`, `#+OPTIONS:`, `#+HTML_HEAD:` and the other
settings keywords apply to the **whole file**, wherever they are written,
even when you export only a subtree. That is why this file shows
file-level keywords inside `#+begin_src org` blocks (those are just code)
and uses `EXPORT_*` properties for the samples. The only live settings
keywords are the few at the top of this file and the `#+MACRO:` lines of
the macros sample.

Each "Sample: &hellip;" heading is followed by an "Exercises: &hellip;" heading with
the **Try:** / **Expect:** steps. Keep the cursor **inside the sample** when you
export: with the cursor in the Exercises heading you would export the
exercise text instead.


<a id="org15303e2"></a>

## Keys in this file

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Keys</th>
<th scope="col" class="org-left">What it does</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>&lt;prefix&gt;e</code> (<code>C-c C-e</code>)</td>
<td class="org-left">open the export dispatcher</td>
</tr>

<tr>
<td class="org-left"><code>s</code> <code>b</code> <code>v</code> <code>a</code></td>
<td class="org-left">toggles: subtree, body only, visible, async</td>
</tr>

<tr>
<td class="org-left"><code>h H</code> / <code>m M</code> / <code>m G</code></td>
<td class="org-left">HTML / Markdown / GFM to a buffer</td>
</tr>

<tr>
<td class="org-left"><code>t A</code> / <code>t U</code> / <code>t L</code></td>
<td class="org-left">ASCII / UTF-8 / Latin-1 text to a buffer</td>
</tr>

<tr>
<td class="org-left"><code>l L</code> / <code>l B</code> / <code>O O</code></td>
<td class="org-left">LaTeX / Beamer / Org to a buffer</td>
</tr>

<tr>
<td class="org-left"><code>#</code></td>
<td class="org-left">insert the export settings template</td>
</tr>

<tr>
<td class="org-left"><code>&lt;Esc&gt;</code></td>
<td class="org-left">close the dispatcher</td>
</tr>

<tr>
<td class="org-left"><code>:Org export ...</code></td>
<td class="org-left">exports without the menu (see below)</td>
</tr>

<tr>
<td class="org-left"><code>&lt;Tab&gt;</code>, <code>&lt;S-Tab&gt;</code></td>
<td class="org-left">fold / unfold (matters for <code>v</code>)</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;'</code> (<code>C-c '</code>)</td>
<td class="org-left">edit a source or export block in a split</td>
</tr>
</tbody>
</table>


<a id="org4dafb16"></a>

# The export dispatcher

`<prefix>e` (Emacs `C-c C-e`) opens a small menu. Each line shows a key in
brackets; press the key, no `<CR>` needed. Keys with `…` open a sub-menu.

The first four lines are **toggles**. Pressing one redraws the menu with the
new value, so you can combine them before choosing a format:

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Key</th>
<th scope="col" class="org-left">Toggle</th>
<th scope="col" class="org-left">Effect when on</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>b</code></td>
<td class="org-left">body only</td>
<td class="org-left">no preamble: no <code>&lt;html&gt;=/=&lt;head&gt;</code>, no</td>
</tr>

<tr>
<td class="org-left">&nbsp;</td>
<td class="org-left">&nbsp;</td>
<td class="org-left"><code>\documentclass</code>, no title block</td>
</tr>

<tr>
<td class="org-left"><code>s</code></td>
<td class="org-left">export scope</td>
<td class="org-left">"subtree": only the subtree at the cursor</td>
</tr>

<tr>
<td class="org-left"><code>v</code></td>
<td class="org-left">visible only</td>
<td class="org-left">skip what is folded right now</td>
</tr>

<tr>
<td class="org-left"><code>a</code></td>
<td class="org-left">async (PDF)</td>
<td class="org-left">compile PDFs in the background (see below)</td>
</tr>
</tbody>
</table>

Then one line per back-end (`h` HTML, `l` LaTeX/Beamer/PDF, `m` Markdown,
`t` plain text, `O` Org, `o` ODT, `d` DOCX, `i` Texinfo, `c` iCalendar,
`P` publish, `p` any pandoc format) and `#` (insert the settings template).
The toggles are reset every time you open the dispatcher.

The same exports without the menu, as an Ex command (the words after the
format are optional and can be in any order):

    :Org export html subtree buffer      " like <prefix>e s h H
    :Org export md subtree body buffer   " subtree, body only, to a buffer
    :Org export ascii visible buffer     " only what is unfolded
    :Org export latex                    " whole file to examples/19-export.tex
    :Org export pdf async open           " compile in the background, then open
    :Org export                          " no format: opens the dispatcher

And from Lua (handy for mappings and scripts): `to_string` returns the text
and writes nothing, `export` behaves like the dispatcher.

    local exp = require("org.export")
    local md = exp.to_string("md", { body_only = true })  -- whole buffer
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local txt = exp.to_string("ascii", { subtree_line = line })
    exp.export("html", { subtree = true, to_buffer = true })
    exp.export("md", { output = "/tmp/notes.md" })   -- choose the file


<a id="orgc8c3ec6"></a>

## Sample: first export

Hello from a **subtree**. It has *emphasis*, `verbatim` and a [link](https://neovim.io).


<a id="orgd81a00d"></a>

### A child heading

Children of the sample become the top-level headings of the output.


<a id="org3ec8003"></a>

## Exercises: first export

**Try:** put the cursor on the line "Hello from a subtree" in the sample
above. Press `<prefix>e`, then `s` (the menu now says "export scope =
subtree"), then `m`, then `M`.

**Expect:** a vertical split with a Markdown buffer. Its whole content is:

    Hello from a **subtree**. It has *emphasis*, `verbatim` and a [link](https://neovim.io).
    
    
    # A child heading
    
    Children of the sample become the top-level headings of the output.

The comment line (`# This is the body ...`) is not there, and Markdown has
no title block, so `EXPORT_TITLE` and `EXPORT_AUTHOR` are not visible.
Close the split with `:q`.

**Try:** same subtree, `<prefix>e s t A` (plain ASCII to a buffer).

**Expect:** now the title and author are centered at the top, and the link
target is listed as a note after the paragraph:

                               _________________
    
                                MY FIRST EXPORT
    
                                      Ada
                               _________________
    
    
    Hello from a *subtree*. It has /emphasis/, `verbatim' and a [link].
    
    
    [link] <https://neovim.io>
    
    
    A child heading
    ===============
    
      Children of the sample become the top-level headings of the output.

**Try:** same subtree, `<prefix>e s b h H` (subtree, **body only**, HTML).

**Expect:** no `<!DOCTYPE>`, `<head>` or title, just the body:

    <p>
    Hello from a <b>subtree</b>. It has <i>emphasis</i>, <code>verbatim</code> and a <a href="https://neovim.io">link</a>.
    </p>
    <div id="outline-container-org6793350" class="outline-2">
    <h2 id="org6793350">A child heading</h2>

(The `org6793350` ids are computed from the content, so they are the same
on every export and change only when you edit the text.)

**Try:** `<prefix>e h H` **without** `s`: the whole file is exported. Search
the HTML buffer for `My first export` with `/`: it is not found, because
`EXPORT_TITLE` only applies to subtree exports; the `<title>` is now
"Export: hands-on examples", from the `#+TITLE:` line at the top.

**Try:** `:Org export md subtree buffer` with the cursor in the sample: the
same Markdown buffer as the first exercise, without the menu.


<a id="org302e170"></a>

## Visible only

With `v` on, whatever is folded at that moment is left out: fold a
subtree with `<Tab>` and its body disappears from the output (its heading
line is visible, so it stays). Useful to export "just the outline" or to
hide parts temporarily.

Combined with `s`, only the visible part of the subtree is exported; if
the subtree's own heading is folded, its body is empty (Emacs does the
same).


<a id="orgc0d11a5"></a>

## Sample: visible only

The intro paragraph is always visible.


<a id="org80a4529"></a>

### Section one

Text of section one.


<a id="orgfee8a47"></a>

### Section two

Text of section two.


<a id="org26715ee"></a>

## Exercises: visible only

**Try:** open the sample above so you see both sections, then fold "Section
one" with `<Tab>` on its heading. Press `<prefix>e v t A` (no `s`: the
whole file, visible parts only). In the output, search with
`/The intro paragraph`.

**Expect:** the fold state of the whole file decides. Around the search hit
you find (section numbers depend on what else is open):

      The intro paragraph is always visible.
    
    
    2.4.1 Section one
    -----------------
    
    
    2.4.2 Section two
    -----------------
    
      Text of section two.

"Text of section one." is missing because it was folded.

**Try:** `<S-Tab>` until the buffer shows only the top-level headings
(OVERVIEW), then `<prefix>e v t A` again: the output is little more than
the table of contents and the numbered top-level headings.


<a id="org29e3bf9"></a>

## Async

`a` only concerns PDF: with it on, LaTeX compilation (`l p`, `l P`) runs in
the background and a message says when the PDF is ready, so you can keep
editing. With the default config it already does
(`export.latex.async_compile = true`); `a` matters when you set that to
`false`. The other formats are fast and always synchronous.
`:Org export pdf async` is the command form.


<a id="orgd5b1c41"></a>

## The settings template (`#`)

`<prefix>e #` asks for an option category (`default`, `html`, `latex`,
`md`, &hellip;; `<Tab>` completes) and inserts every option with its current
value:

-   without `s`: `#+options:` lines and `#+title:`, `#+author:`, `#+date:`,
    `#+email:`, `#+language:`, `#+select_tags:` &hellip; keywords **at the cursor**;
-   with `s`: `EXPORT_OPTIONS`, `EXPORT_TITLE`, `EXPORT_AUTHOR`, &hellip; properties
    in the drawer of the current heading.


<a id="org6d2fcfd"></a>

### Scratch heading for the template

**Try:** put the cursor on the heading above, press `<prefix>e s #` and
accept `default` with `<CR>`.

**Expect:** a `:PROPERTIES:` drawer appears under "Scratch heading for the
template". The values are the **defaults** (from your config), not what
this file sets:

    :PROPERTIES:
    :EXPORT_OPTIONS: ':nil *:t -:t ::t <:t H:3 \n:nil ^:t arch:headline author:t ...
    :EXPORT_TITLE: 19-export
    :EXPORT_DATE: <2026-09-28 Mon>
    :EXPORT_AUTHOR: (your name)
    :EXPORT_EMAIL:
    :EXPORT_LANGUAGE: en
    :EXPORT_SELECT_TAGS: export
    :EXPORT_EXCLUDE_TAGS: noexport
    :EXPORT_CREATOR: Neovim 0.x.y (org.nvim, Org mode 9.8 compatible)
    :EXPORT_CITE_EXPORT:
    :END:

(the date is the day you do it). Delete what you don't need and edit the
rest; press `u` to take it all out again.

**Try:** on the empty line below, `<prefix>e #` (no `s`) and `<CR>`.

**Expect:** five `#+options:` lines, then `#+title: 19-export`, `#+date:
<...>`, `#+author: ...`, `#+email:`, `#+language: en`, `#+select_tags:
export`, `#+exclude_tags: noexport`, `#+creator: ...` and `#+cite_export:`,
inserted at the cursor. Press `u`: left in place they would change every
export of this file!


<a id="orgd279195"></a>

# Back-ends and the tools they need

Everything marked "none" is pure Lua and works out of the box. The `o`
keys (`h o`, `m o`, `l o`, &hellip;) also open the file with your system's
viewer. `p` asks for a pandoc format name (`rst`, `epub`, `typst`,
`mediawiki`, `asciidoc`, &hellip;). PDF uses `export.latex.compiler`
(`pdflatex` by default) through `latexmk` when it is installed. ODT is
zipped in Lua; LibreOffice is only needed to convert it further (see
`export.odt.preferred_output_format`).

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Back-end</th>
<th scope="col" class="org-left">Keys (buffer / file)</th>
<th scope="col" class="org-left">External tool</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left">HTML</td>
<td class="org-left"><code>h H</code> / <code>h h</code>, <code>h o</code></td>
<td class="org-left">none</td>
</tr>

<tr>
<td class="org-left">Markdown</td>
<td class="org-left"><code>m M</code> / <code>m m</code>, <code>m o</code></td>
<td class="org-left">none</td>
</tr>

<tr>
<td class="org-left">GitHub Markdown</td>
<td class="org-left"><code>m G</code> / <code>m g</code></td>
<td class="org-left">none</td>
</tr>

<tr>
<td class="org-left">ASCII</td>
<td class="org-left"><code>t A</code> / <code>t a</code></td>
<td class="org-left">none</td>
</tr>

<tr>
<td class="org-left">Latin-1</td>
<td class="org-left"><code>t L</code> / <code>t l</code></td>
<td class="org-left">none</td>
</tr>

<tr>
<td class="org-left">UTF-8</td>
<td class="org-left"><code>t U</code> / <code>t u</code></td>
<td class="org-left">none</td>
</tr>

<tr>
<td class="org-left">Org</td>
<td class="org-left"><code>O O</code> / <code>O o</code>, <code>O v</code></td>
<td class="org-left">none</td>
</tr>

<tr>
<td class="org-left">LaTeX</td>
<td class="org-left"><code>l L</code> / <code>l l</code></td>
<td class="org-left">none</td>
</tr>

<tr>
<td class="org-left">PDF</td>
<td class="org-left">- / <code>l p</code>, <code>l o</code></td>
<td class="org-left">latexmk or pdflatex</td>
</tr>

<tr>
<td class="org-left">Beamer</td>
<td class="org-left"><code>l B</code> / <code>l b</code></td>
<td class="org-left">none</td>
</tr>

<tr>
<td class="org-left">Beamer PDF</td>
<td class="org-left">- / <code>l P</code>, <code>l O</code></td>
<td class="org-left">latexmk or pdflatex</td>
</tr>

<tr>
<td class="org-left">ODT</td>
<td class="org-left">- / <code>o o</code>, <code>o O</code></td>
<td class="org-left">none</td>
</tr>

<tr>
<td class="org-left">DOCX</td>
<td class="org-left">- / <code>d d</code>, <code>d o</code></td>
<td class="org-left">pandoc</td>
</tr>

<tr>
<td class="org-left">other formats</td>
<td class="org-left">- / <code>p</code> + format name</td>
<td class="org-left">pandoc</td>
</tr>

<tr>
<td class="org-left">Texinfo</td>
<td class="org-left">- / <code>i t</code></td>
<td class="org-left">none</td>
</tr>

<tr>
<td class="org-left">Info</td>
<td class="org-left">- / <code>i i</code>, <code>i o</code></td>
<td class="org-left">makeinfo</td>
</tr>

<tr>
<td class="org-left">iCalendar</td>
<td class="org-left">- / <code>c f</code>, <code>c a</code>, <code>c c</code></td>
<td class="org-left">none</td>
</tr>
</tbody>
</table>

-   ODT, DOCX, pandoc formats, Texinfo, PDF and iCalendar are always written
    to **files** (there is no buffer variant). Only try them if you are happy
    to get `examples/19-export.odt` etc. in the repo (delete them after).
-   `:checkhealth org` reports which of the optional tools are installed.
-   Pandoc exports first run the Org back-end (macros, `#+INCLUDE`,
    `noexport` are handled by org.nvim), then pipe the result to pandoc.


<a id="org3c0e124"></a>

# Document keywords: title, author, date, &hellip;

These keywords fill the title block (HTML `<title>` and `<h1>`, LaTeX
`\title{}`, the centered banner of the text export, ODT metadata):

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Keyword</th>
<th scope="col" class="org-left">Meaning</th>
<th scope="col" class="org-left">Property</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>#+TITLE:</code></td>
<td class="org-left">document title</td>
<td class="org-left"><code>EXPORT_TITLE</code></td>
</tr>

<tr>
<td class="org-left"><code>#+SUBTITLE:</code></td>
<td class="org-left">subtitle (HTML, LaTeX, text)</td>
<td class="org-left"><code>..._SUBTITLE</code></td>
</tr>

<tr>
<td class="org-left"><code>#+AUTHOR:</code></td>
<td class="org-left">author; default: your name</td>
<td class="org-left"><code>EXPORT_AUTHOR</code></td>
</tr>

<tr>
<td class="org-left"><code>#+EMAIL:</code></td>
<td class="org-left">shown only with <code>email:t</code></td>
<td class="org-left"><code>EXPORT_EMAIL</code></td>
</tr>

<tr>
<td class="org-left"><code>#+DATE:</code></td>
<td class="org-left">any text or a timestamp</td>
<td class="org-left"><code>EXPORT_DATE</code></td>
</tr>

<tr>
<td class="org-left"><code>#+LANGUAGE:</code></td>
<td class="org-left">translates generated words</td>
<td class="org-left"><code>..._LANGUAGE</code></td>
</tr>

<tr>
<td class="org-left"><code>#+CREATOR:</code></td>
<td class="org-left">shown only with <code>creator:t</code></td>
<td class="org-left"><code>..._CREATOR</code></td>
</tr>

<tr>
<td class="org-left"><code>#+KEYWORDS:</code></td>
<td class="org-left">HTML/ODT metadata</td>
<td class="org-left"><code>..._KEYWORDS</code></td>
</tr>

<tr>
<td class="org-left"><code>#+DESCRIPTION:</code></td>
<td class="org-left">HTML/ODT metadata</td>
<td class="org-left"><code>..._DESCRIPTION</code></td>
</tr>

<tr>
<td class="org-left"><code>#+EXPORT_FILE_NAME:</code></td>
<td class="org-left">output file name (no extension)</td>
<td class="org-left"><code>..._FILE_NAME</code></td>
</tr>
</tbody>
</table>

(`..._X` stands for `EXPORT_X`.) `#+LANGUAGE:` translates the words the
exporter writes itself: "Table of Contents", "Footnotes", "Figure", &hellip;
In a file they look like this (an example only, not live settings):

    #+TITLE: Quarterly report
    #+SUBTITLE: Third quarter 2026
    #+AUTHOR: Ada Lovelace
    #+EMAIL: ada@example.org
    #+DATE: <2026-10-01 Thu>
    #+LANGUAGE: en
    #+OPTIONS: email:t toc:nil
    #+EXPORT_FILE_NAME: q3-report


<a id="orgef0656a"></a>

## Sample: title block

Revenue went up.


<a id="org6123cb4"></a>

## Exercises: title block

**Try:** cursor on "Revenue went up.", `<prefix>e s t A`.

**Expect:** a banner with the title, the subtitle, the author, the e-mail
(because of `email:t`) and the date:

                              ____________________
    
                                QUARTERLY REPORT
                               Third quarter 2026
    
                                  Ada Lovelace
                                ada@example.org
                              ____________________
    
    
                                <2026-10-01 Thu>
    
    
    Revenue went up.

**Try:** `<prefix>e s h H` and look at the top of the HTML buffer.

**Expect:** the title in `<head>`, and as the first heading with the
subtitle under it:

    <title>Quarterly report</title>
    <meta name="author" content="Ada Lovelace" />
    ...
    <h1 class="title">Quarterly report
    <br />
    <span class="subtitle">Third quarter 2026</span>
    </h1>

and at the end a postamble with the date, author, e-mail link and the
creation time of the export (`timestamp:t`):

    <div id="postamble" class="status">
    <p class="date">Date: 2026-10-01 Thu 00:00</p>
    <p class="author">Author: Ada Lovelace</p>
    <p class="email">Email: <a href="mailto:ada@example.org">ada@example.org</a></p>
    <p class="date">Created: 2026-09-28 Mon 15:13</p>

**Try:** `<prefix>e s l L` (LaTeX to a buffer).

**Expect:** the e-mail becomes a `\thanks`, the subtitle a second title line:

    \author{Ada Lovelace\thanks{ada@example.org}}
    \date{\textit{<2026-10-01 Thu>}}
    \title{Quarterly report\\\medskip
    \large Third quarter 2026}

**Try:** change `email:t` to `email:nil` in `EXPORT_OPTIONS` and export as
ASCII again: the `ada@example.org` line disappears. With `date:nil` the
date goes, with `author:nil` the author.


<a id="orgd782e4f"></a>

## Sample: another language

Voir la note<sup><a id="fnr.fr" class="footref" href="#fn.fr" role="doc-backlink">1</a></sup>.


<a id="org7cb858b"></a>

### Première partie

Du texte.


<a id="org6063be0"></a>

## Exercises: another language

**Try:** `<prefix>e s t U` (UTF-8 text to a buffer).

**Expect:** the words the exporter generates are in French:

    Table des matières
    ──────────────────
    
    1. Première partie
    
    
    Voir la note[1].
    
    
    1 Première partie
    ═════════════════
    
      Du texte.
    
    
    
    Notes de bas de page
    ────────────────────
    
    [1] Une note de bas de page.

**Try:** `<prefix>e s t A` (plain ASCII): the table of contents is now
titled `Sommaire`, the ASCII-only form of the French dictionary.

**Try:** change `fr` to `de` and export again: `Inhaltsverzeichnis` and
`Fußnoten`.


<a id="orgd462ce2"></a>

# #+OPTIONS: the export switches

`#+OPTIONS:` takes `key:value` pairs separated by spaces; in a subtree the
same pairs go in `EXPORT_OPTIONS`. Several `#+OPTIONS:` lines add up. Values
are Emacs Lisp: `t` (yes), `nil` (no), numbers, strings, lists like
`("TODO" "NEXT")`. The defaults come from the `export` table of your
config (`with_toc`, `headline_levels`, &hellip;).

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Option</th>
<th scope="col" class="org-left">Default</th>
<th scope="col" class="org-left">Meaning</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>toc:</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left">table of contents; a number = its depth</td>
</tr>

<tr>
<td class="org-left"><code>num:</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left">section numbers; a number = how deep</td>
</tr>

<tr>
<td class="org-left"><code>H:</code></td>
<td class="org-left"><code>3</code></td>
<td class="org-left">deeper headings become list items</td>
</tr>

<tr>
<td class="org-left"><code>^:</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left"><code>a_b</code>, <code>a^b</code>; <code>{}</code> only <code>a_{b}</code>; <code>nil</code> off</td>
</tr>

<tr>
<td class="org-left"><code>*:</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left">emphasis (<code>*bold*</code>, <code>/italic/</code>, &hellip;)</td>
</tr>

<tr>
<td class="org-left"><code>tags:</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left">headline tags; <code>not-in-toc</code></td>
</tr>

<tr>
<td class="org-left"><code>todo:</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left">TODO keywords</td>
</tr>

<tr>
<td class="org-left"><code>pri:</code></td>
<td class="org-left"><code>nil</code></td>
<td class="org-left">priority cookies <code>[#A]</code></td>
</tr>

<tr>
<td class="org-left"><code>tasks:</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left">TODO entries: <code>nil</code>, <code>todo</code>, <code>done</code>, list</td>
</tr>

<tr>
<td class="org-left"><code>stat:</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left">statistics cookies <code>[1/3]</code></td>
</tr>

<tr>
<td class="org-left"><code>prop:</code></td>
<td class="org-left"><code>nil</code></td>
<td class="org-left">property drawers; <code>t</code> or a list of names</td>
</tr>

<tr>
<td class="org-left"><code>d:</code></td>
<td class="org-left">see below</td>
<td class="org-left">drawers: <code>t</code>, <code>nil</code>, list, <code>(not ...)</code></td>
</tr>

<tr>
<td class="org-left"><code>p:</code></td>
<td class="org-left"><code>nil</code></td>
<td class="org-left">SCHEDULED, DEADLINE and CLOSED lines</td>
</tr>

<tr>
<td class="org-left"><code>c:</code></td>
<td class="org-left"><code>nil</code></td>
<td class="org-left">CLOCK lines</td>
</tr>

<tr>
<td class="org-left"><code>&lt;:</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left">paragraphs made only of timestamps</td>
</tr>

<tr>
<td class="org-left"><code>timestamp:</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left">creation time (HTML postamble)</td>
</tr>

<tr>
<td class="org-left"><code>f:</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left">footnotes</td>
</tr>

<tr>
<td class="org-left"><code>\n:</code></td>
<td class="org-left"><code>nil</code></td>
<td class="org-left">keep every line break</td>
</tr>

<tr>
<td class="org-left"><code>':</code></td>
<td class="org-left"><code>nil</code></td>
<td class="org-left">smart quotes</td>
</tr>

<tr>
<td class="org-left"><code>-:</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left"><code>--</code>, <code>---</code>, <code>...</code> as dashes and ellipsis</td>
</tr>

<tr>
<td class="org-left"><code>e:</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left">entities like <code>\alpha</code></td>
</tr>

<tr>
<td class="org-left"><code>tex:</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left">LaTeX fragments; <code>verbatim</code>, <code>nil</code></td>
</tr>

<tr>
<td class="org-left"><code>\vert:</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left">tables (the key is a pipe character)</td>
</tr>

<tr>
<td class="org-left"><code>::</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left">fixed-width lines (<code>: text</code>)</td>
</tr>

<tr>
<td class="org-left"><code>arch:</code></td>
<td class="org-left"><code>headline</code></td>
<td class="org-left">archived trees: <code>t</code>, <code>nil</code>, <code>headline</code></td>
</tr>

<tr>
<td class="org-left"><code>inline:</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left">inline tasks</td>
</tr>

<tr>
<td class="org-left"><code>title:</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left">the title</td>
</tr>

<tr>
<td class="org-left"><code>author:</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left">the author</td>
</tr>

<tr>
<td class="org-left"><code>date:</code></td>
<td class="org-left"><code>t</code></td>
<td class="org-left">the date</td>
</tr>

<tr>
<td class="org-left"><code>email:</code></td>
<td class="org-left"><code>nil</code></td>
<td class="org-left">the e-mail</td>
</tr>

<tr>
<td class="org-left"><code>creator:</code></td>
<td class="org-left"><code>nil</code></td>
<td class="org-left">the creator string</td>
</tr>

<tr>
<td class="org-left"><code>broken-links:</code></td>
<td class="org-left"><code>nil</code></td>
<td class="org-left"><code>nil</code> error, <code>t</code> drop, <code>mark</code> mark</td>
</tr>
</tbody>
</table>

The default of `d:` is `(not "LOGBOOK")`: every drawer but LOGBOOK. In
the table the pipe key is shown as `\vert:` because a bare `|` would
split the cell; in `#+OPTIONS:` you write `|:nil`.


<a id="org1040116"></a>

## Sample: toc, num and H

Intro.


<a id="org6f725ab"></a>

### Chapter

1.  Section

    1.  Too deep to be a section
    
        This one becomes a list item.


<a id="org439ff3f"></a>

### Another chapter

Text.


<a id="org8f07deb"></a>

## Exercises: toc, num and H

**Try:** `<prefix>e s t A`.

**Expect:** a table of contents with two levels, numbered sections, and the
third level turned into a list item (a `*` bullet) under 1.1:

    Table of Contents
    _________________
    
    1. Chapter
    .. 1. Section
    2. Another chapter
    
    
    Intro.
    
    
    1 Chapter
    =========
    
    1.1 Section
    ~~~~~~~~~~~
    
    * 1.1.1 Too deep to be a section
    
      This one becomes a list item.
    
    
    2 Another chapter
    =================
    
      Text.

**Try:** change `EXPORT_OPTIONS` to `toc:nil num:1 H:2 title:nil author:nil`
and export again: no table of contents, and only the first level is
numbered: `1 Chapter`, then `Section` without a number, then
`* Too deep to be a section`, then `2 Another chapter`.

**Try:** `H:3` instead of `H:2`: "Too deep to be a section" is a real
(sub-sub)section again, underlined with dashes.


<a id="org297da5f"></a>

## Sample: sub- and superscripts

file<sub>name</sub> and x<sup>2</sup> stay as they are, but H<sub>2</sub>O and E = mc<sup>2</sup> are converted.


<a id="orgaa3a7e6"></a>

## Exercises: sub- and superscripts

**Try:** `<prefix>e s b m M` (body only, Markdown).

**Expect:**

    file\_name and x^2 stay as they are, but H<sub>2</sub>O and E = mc<sup>2</sup> are converted.

**Try:** change `^:{}` to `^:t` and export again: `file_name` becomes
`file<sub>name</sub>` and `x^2` becomes `x<sup>2</sup>` too. With `^:nil` nothing is converted. `^:{}` is
the usual choice for documents full of snake<sub>case</sub> names.


<a id="org05944c1"></a>

## Sample: tags, TODO keywords and priorities


<a id="orgb6fc2e2"></a>

### TODO Write the report     :work:


<a id="org7586be0"></a>

### DONE Book the room     :office:


<a id="org652c872"></a>

### NEXT Plan the offsite <code>[1/2]</code>

-   [X] pick a date
-   [ ] pick a place


<a id="org4b1d8d6"></a>

## Exercises: tags, TODO keywords and priorities

**Try:** `<prefix>e s b m M`.

**Expect:** keywords, priorities, cookies and tags are all there (the
statistics cookie is wrapped in `<code>`, like Emacs does):

    # TODO [#A] Write the report     :work:
    
    
    # DONE Book the room     :office:
    
    
    # NEXT [#C] Plan the offsite <code>[1/2]</code>
    
    -   [X] pick a date
    -   [ ] pick a place

**Try:** set `EXPORT_OPTIONS` to `toc:nil num:nil title:nil author:nil
tags:nil todo:nil pri:nil stat:nil` (one line) and export again: the
headings become plain `# Write the report`, `# Book the room` and
`# Plan the offsite`; the checklist stays.

**Try:** replace `tags:t todo:t pri:t` by `tasks:todo`: only the not-done
entries are exported (`# TODO Write the report     :work:` and
`# NEXT Plan the offsite <code>[1/2]</code>`; the priority is gone too
because `pri:` is `nil` by default). `tasks:done` keeps only "Book the
room", `tasks:("NEXT")` only "Plan the offsite", `tasks:nil` drops all
three.


<a id="org6d62026"></a>

## Sample: drawers, planning, clocks and timestamps


<a id="orgab33211"></a>

### DONE Ship the release

Remember to tag the commit.

<span class="timestamp-wrapper"><span class="timestamp">&lt;2026-10-05 Mon&gt;</span></span>

The release went out on time.


<a id="orgcf0df04"></a>

## Exercises: drawers, planning, clocks and timestamps

**Try:** `<prefix>e s b t A`.

**Expect:** by default only the heading, the NOTES drawer (every drawer but
LOGBOOK is exported), the lone timestamp and the paragraph:

    DONE Ship the release
    =====================
    
      Remember to tag the commit.
      <2026-10-05 Mon>
    
      The release went out on time.

**Try:** one at a time, add these to `EXPORT_OPTIONS` and export again
(each adds or removes lines between the underline and "Remember to tag"):

-   `p:t` adds `CLOSED: [2026-09-25 Fri 17:02]  SCHEDULED: <2026-09-24 Thu>`;
-   `prop:t` adds `VERSION: 2.1` and `OWNER: Ada`; `prop:("OWNER")` only
    `OWNER: Ada`;
-   `c:t` alone changes nothing: the clock line is inside LOGBOOK, which is
    still excluded. `c:t d:t` (all drawers) shows
    `CLOCK: [2026-09-24 Thu 09:00]--[2026-09-24 Thu 11:30]  =>  2:30`;
-   `d:nil` removes "Remember to tag the commit." (no drawers at all);
    `d:("NOTES")` exports only the NOTES drawer (same output as now);
-   `<:nil` removes `<2026-10-05 Mon>`, the paragraph made only of a
    timestamp (an empty line is left in its place).


<a id="org85dfe2e"></a>

## Sample: line breaks, quotes, special strings

Roses are red,
violets are blue.
"Quoted" text &ndash; with an en dash &mdash; and an em dash&hellip;


<a id="org8ba8d27"></a>

## Exercises: line breaks, quotes, special strings

**Try:** `<prefix>e s b h H`.

**Expect:** each line ends with `<br />` (from `\n:t`), the quotes become
curly (`':t`) and the dashes and dots entities (`-:t`):

    <p>
    Roses are red,<br />
    violets are blue.<br />
    &ldquo;Quoted&rdquo; text &ndash; with an en dash &mdash; and an em dash&hellip;<br />
    </p>

**Try:** set `EXPORT_OPTIONS` to `toc:nil title:nil author:nil \n:nil ':nil
-:nil` and export again: the three lines come back as typed, with
straight quotes, `--`, `---` and `...`, and no `<br />`.


<a id="orga176ef6"></a>

## Sample: what to leave out entirely

A **bold** claim&alpha; with a footnote<sup><a id="fnr.omit" class="footref" href="#fn.omit" role="doc-backlink">2</a></sup>.

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<tbody>
<tr>
<td class="org-left">a table</td>
<td class="org-left">is dropped</td>
</tr>
</tbody>
</table>

    fixed-width lines are dropped too


<a id="org6edcd02"></a>

## Exercises: what to leave out entirely

**Try:** `<prefix>e s b m M`.

**Expect:** only one line: the asterisks stay literal (`*:nil`), `\alpha`
stays as typed (`e:nil`), no footnote, no table, no fixed-width line.
Markdown escapes the characters that would otherwise be markup, so you see
backslashes:

    A \*bold\* claim\\alpha with a footnote.

**Try:** remove `*:nil e:nil` and export again. Now the emphasis is
converted and the entity is written as HTML:

    A **bold** claim&alpha; with a footnote.


<a id="orgaaaef3c"></a>

# Choosing what is exported


<a id="org6f52acd"></a>

## Tags: noexport and export

-   A heading tagged `:noexport:` is removed with its whole subtree.
-   If **any** heading carries an `:export:` tag, **only** the tagged subtrees
    are exported (in a whole-file export the text before the first heading
    is kept too).
-   `#+EXCLUDE_TAGS:` / `#+SELECT_TAGS:` (or the `EXPORT_EXCLUDE_TAGS` /
    `EXPORT_SELECT_TAGS` properties) replace those tag lists. Tags are
    inherited: a child of a `:noexport:` heading goes too.


<a id="org732606e"></a>

## Sample: noexport


<a id="org1af4fa9"></a>

### Kept

Public text.


<a id="org9320ec8"></a>

### Also kept

More public text.


<a id="orgc8654cb"></a>

## Exercises: noexport

**Try:** `<prefix>e s b m M`.

**Expect:** two headings only, "Kept" and "Also kept"; no "Private text":

    # Kept
    
    Public text.
    
    
    # Also kept
    
    More public text.


<a id="org8de3f27"></a>

## Sample: select tags

Intro text of the sample.


<a id="org05b67b0"></a>

### Chosen     :keep:

In.


<a id="org58c3b7f"></a>

### Not chosen

Out: no keep tag, and another heading has one.


<a id="org19028c7"></a>

### Chosen but secret     :keep:secret:

Out: exclude tags win.


<a id="orgd7ba314"></a>

## Exercises: select tags

**Try:** `<prefix>e s b m M`.

**Expect:** only the heading "Chosen". Even the intro text is dropped: in a
subtree export it belongs to the sample heading, which is not selected
(Emacs does the same).

    # Chosen
    
    In.

**Try:** remove the `keep` tag from **both** "Chosen" headings (edit the
lines, or `<prefix>t` on each heading and delete `keep` from the prompt).
Now no heading is selected, so the select tags do not apply at all:

    Intro text of the sample.
    
    
    # Chosen
    
    In.
    
    
    # Not chosen
    
    Out: no keep tag, and another heading has one.

"Chosen but secret" is still excluded by its `secret` tag. Press `u` to
restore the tags.


<a id="org40ca3d5"></a>

## Sample: COMMENT headings, comment lines and blocks

Visible paragraph.


<a id="org58060d5"></a>

### Finished part

Done.


<a id="org9d95138"></a>

## Exercises: COMMENT headings, comment lines and blocks

**Try:** `<prefix>e s b m M`.

**Expect:**

    Visible paragraph.
    
    
    # Finished part
    
    Done.

**Try:** put the cursor on the "COMMENT Work in progress" heading and press
`<prefix>hC` (toggle COMMENT, Emacs `C-c ;`): the word COMMENT goes away.
Export again: "Work in progress" and its text are now exported between
"Visible paragraph." and "Finished part". Press `<prefix>hC` again to put
it back.


<a id="orgfc3831a"></a>

## Sample: archived trees


<a id="org2f1a4d1"></a>

### Current work

Live.


<a id="org610520a"></a>

### Old project     :ARCHIVE:


<a id="orgaeccd88"></a>

## Exercises: archived trees

**Try:** `<prefix>e s b m M`.

**Expect:** "Old project" appears as a heading, but "Old details." is gone
(`arch:headline`, the default):

    # Current work
    
    Live.
    
    
    # Old project

**Try:** add `arch:t` to `EXPORT_OPTIONS`: "Old details." comes back. With
`arch:nil` the "Old project" heading goes too.


<a id="orgb494fdc"></a>

# Subtree properties (EXPORT<sub>\*</sub>)

When you export a subtree, every export keyword can be set in its drawer as
`EXPORT_<KEYWORD>`: `EXPORT_TITLE`, `EXPORT_AUTHOR`, `EXPORT_DATE`,
`EXPORT_EMAIL`, `EXPORT_OPTIONS`, `EXPORT_FILE_NAME`, `EXPORT_LANGUAGE`,
`EXPORT_SELECT_TAGS`, `EXPORT_EXCLUDE_TAGS`, and the back-end ones
(`EXPORT_HTML_HEAD`, `EXPORT_LATEX_CLASS`, `EXPORT_LATEX_HEADER`, &hellip;).

-   `EXPORT_OPTIONS` is merged with `#+OPTIONS`: keys it names win, others
    keep the file value.
-   Without `EXPORT_TITLE`, a subtree export is titled after the heading.
-   These properties are ignored when the whole file is exported.


<a id="orgfb87ab7"></a>

## Sample: a subtree is its own document

A standalone page made from one heading.


<a id="orge417ad7"></a>

## Exercises: a subtree is its own document

**Try:** `<prefix>e s h H`.

**Expect:** `<title>Sample: a subtree is its own document</title>`, the meta
line from `EXPORT_HTML_HEAD` inside `<head>`, and "Author: Grace" in the
postamble.

**Try (writes a file outside the repo):** `<prefix>e s m m`. Because of
`EXPORT_FILE_NAME`, the message says `Exported to /tmp/org-nvim-sample.md`
(the extension is added for you). A relative name would be relative to
this file, i.e. inside `examples/`.


<a id="org6669e35"></a>

# Table of contents

-   `toc:t` / `toc:nil` / `toc:2` in `#+OPTIONS:` control the table at the
    top.
-   `#+TOC: headlines 2` puts a table of contents **where the keyword is**;
    add `local` for only the headings below the current one. `#+TOC: tables`
    and `#+TOC: listings` list the captioned tables and source blocks.
-   A heading with `:UNNUMBERED: t` has no number; `:UNNUMBERED: notoc` also
    keeps it out of the table of contents.


<a id="orgd093eb4"></a>

## Sample: tables of contents


# Table of Contents

1.  [How to use this file](#org97668aa)
2.  [The export dispatcher](#org4dafb16)
3.  [Back-ends and the tools they need](#orgd279195)
4.  [Document keywords: title, author, date, &hellip;](#org3c0e124)
5.  [#+OPTIONS: the export switches](#orgd462ce2)
6.  [Choosing what is exported](#orgaaaef3c)
7.  [Subtree properties (EXPORT<sub>\*</sub>)](#orgb494fdc)
8.  [Table of contents](#org6669e35)
9.  [Captions, names and cross-references](#orge018dd6)
10. [Footnotes in export](#orgcf84e55)
11. [Macros](#org254f1b8)
12. [Raw output for one back-end](#orgc1855ad)
13. [HTML specifics: #+ATTR<sub>HTML</sub> and #+HTML<sub>HEAD</sub>](#org42d1764)
14. [LaTeX and PDF specifics](#org2580b9d)
15. [Beamer slides](#orga657571)
16. [Markdown, GFM, plain text and Org](#org5f1eceb)
17. [#+INCLUDE: pulling in other files](#org5b7a29e)
18. [Source blocks and :exports](#org617150d)
19. [Citations](#org4554367)
20. [Broken links](#org0acc137)
21. [iCalendar, ODT, DOCX, Texinfo and pandoc (file exports)](#org0373b60)
22. [Hugo blog posts (the hugo extension)](#orge3c0000)
23. [Publishing projects](#org254b633)
24. [Configuring defaults](#org8185bc2)
25. [Further reading](#orgce04e31)


<a id="org8228d88"></a>

### Preface

No number here.


<a id="orgceb5939"></a>

### Setup



1.  Install

2.  Configure


### Colophon

Not in the table of contents.


<a id="orgb6d0386"></a>

## Exercises: tables of contents

**Try:** `<prefix>e s b t A`.

**Expect:** a first list with the level-1 headings (`Preface` without a
number, `1. Setup`, no Colophon), then under "1 Setup" a local list with
only its children:

    Table of Contents
    _________________
    
    Preface
    1. Setup
    
    
    Preface
    =======
    
      No number here.
    
    
    1 Setup
    =======
    
      .. 1. Install
      .. 2. Configure
    
    
    1.1 Install
    ~~~~~~~~~~~
    
    
    1.2 Configure
    ~~~~~~~~~~~~~
    
    
    Colophon
    ========
    
      Not in the table of contents.

**Try:** change `#+TOC: headlines 1` to `#+TOC: headlines 2`: the first list
now also shows `.. 1. Install` and `.. 2. Configure` under `1. Setup`.


<a id="orge018dd6"></a>

# Captions, names and cross-references

-   `#+CAPTION:` before a table, image or source block gives it a caption;
    exported it is numbered: "Table 1:", "Figure 1:", "Listing 1:".
-   `#+NAME:` gives it a name; `[[name]]` links to it and is replaced by its
    number on export.
-   `[[*Heading]]` links to a heading (by its text), `[[#my-id]]` to a
    heading with `:CUSTOM_ID: my-id`, `<<target>>` is an anchor you link to
    with `[[target]]`, and `<<<radio target>>>` turns every occurrence of
    the words into a link.
-   A link with a description shows the description; without one, a link to
    a numbered heading shows the section number, a link to a named table
    its table number.


<a id="org627852b"></a>

## Sample: cross-references


<a id="data"></a>

### Data

<table id="org5d404f1" border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">
<caption class="t-above"><span class="table-number">Table 1:</span> Monthly sales</caption>

<colgroup>
<col  class="org-left" />

<col  class="org-right" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Month</th>
<th scope="col" class="org-right">Units</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left">Oct</td>
<td class="org-right">12</td>
</tr>

<tr>
<td class="org-left">Nov</td>
<td class="org-right">17</td>
</tr>
</tbody>
</table>

    return 2 * 21

The procedure:

1.  Collect the numbers.
2.  <a id="org39e4553"></a>Check the totals.


<a id="org301e875"></a>

### Discussion

See table [7](#org5d404f1), listing [5](#orgb2d68da) and section [9.1.1](#data). The
same section by id: [the data section](#data). Never skip step [2](#org39e4553).


<a id="org93312df"></a>

## Exercises: cross-references

**Try:** `<prefix>e s b h H` and look for "Discussion".

**Expect:** the captions are numbered, the named elements and the target get
ids, and the links point to them. The heading with a `CUSTOM_ID` uses it
as its id (`data`); the other ids look like `org` plus 7 hex digits:

    <h2 id="data"><span class="section-number-2">1.</span> Data</h2>
    <table id="orgc141a8c" border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">
    <caption class="t-above"><span class="table-number">Table 1:</span> Monthly sales</caption>
    ...
    <label class="org-src-name"><span class="listing-number">Listing 1: </span>Doubling a number</label><pre class="src src-lua" id="org608ce3d"><code>return 2 * 21
    ...
    <li><a id="org7457e97"></a>Check the totals.</li>
    ...
    See table <a href="#orgc141a8c">1</a>, listing <a href="#org608ce3d">1</a> and section <a href="#data">1</a>. The
    same section by id: <a href="#data">the data section</a>. Never skip step <a href="#org7457e97">2</a>.

A link to a `<<target>>` without a description shows the number of what
holds the target: here the list item, so "step 2".

(The generated ids are computed from the content, so they stay the same
from one export to the next.)

**Try:** `<prefix>e s b t A`: in plain text the references are just the
numbers, and the table and the listing get their captions below them:

       Month  Units
      --------------
       Oct       12
       Nov       17
      Table 1: Monthly sales
    
      ,----
      | return 2 * 21
      `----
      Listing 1: Doubling a number
    ...
      See table 1, listing 1 and section 1. The same section by id: [the
      data section]. Never skip step 2.
    
    
    [the data section] See section 1

(The last line is the plain-text version of a described link: a note
after the section.)

**Try:** in the Discussion paragraph, replace `[[*Data]]` by `[[*Dataa]]` and
export again: the link no longer resolves. Thanks to `broken-links:mark` at
the top of this file you get `[BROKEN LINK: *Dataa]` instead of an error
(see "Broken links" below). Press `u`.


<a id="orgcf84e55"></a>

# Footnotes in export

Footnotes are numbered in order of first reference and collected at the
end of the document (HTML: a "Footnotes" section; LaTeX: real
`\footnote{}`; Markdown: a "Footnotes" section with links; text: a
"Footnotes" section). Named `[fn:name]`, anonymous inline `[fn::text]` and
named inline `[fn:name:text]` footnotes all work. `f:nil` drops them.


<a id="org52a16be"></a>

## Sample: footnotes

A named note<sup><a id="fnr.sample" class="footref" href="#fn.sample" role="doc-backlink">3</a></sup>, an inline one<sup><a id="fnr.4" class="footref" href="#fn.4" role="doc-backlink">4</a></sup> and the
named note again<sup><a id="fnr.sample.3" class="footref" href="#fn.sample" role="doc-backlink">3</a></sup>.


<a id="org5739b0a"></a>

## Exercises: footnotes

**Try:** `<prefix>e s b t A`.

**Expect:** references become `[1]` and `[2]` (the second use of `sample`
is `[1]` again), with a footnotes section at the end:

    A named note[1], an inline one[2] and the named note again[1].
    ...
    Footnotes
    _________
    
    [1] The definition of the named note.
    
    [2] Defined right here.

More on footnotes: [14-footnotes.org](14-footnotes.md).


<a id="org254f1b8"></a>

# Macros

`#+MACRO: name replacement text` defines a macro; `{{{name}}}` uses it.
`$1`, `$2` &hellip; are the arguments (separated by commas; `\,` is a literal
comma). Macros are expanded on export only, anywhere in the text.

Built-in macros:

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Macro</th>
<th scope="col" class="org-left">Expands to</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>{{{title}}}</code></td>
<td class="org-left">the document title</td>
</tr>

<tr>
<td class="org-left"><code>{{{author}}}</code> <code>{{{email}}}</code></td>
<td class="org-left">author, e-mail</td>
</tr>

<tr>
<td class="org-left"><code>{{{date}}}</code>, <code>{{{date(%Y)}}}</code></td>
<td class="org-left">the <code>#+DATE</code> (formatted if a timestamp)</td>
</tr>

<tr>
<td class="org-left"><code>{{{time(%H:%M)}}}</code></td>
<td class="org-left">the time of the export</td>
</tr>

<tr>
<td class="org-left"><code>{{{modification-time(%F)}}}</code></td>
<td class="org-left">the file's modification time</td>
</tr>

<tr>
<td class="org-left"><code>{{{input-file}}}</code></td>
<td class="org-left">the file name</td>
</tr>

<tr>
<td class="org-left"><code>{{{keyword(NAME)}}}</code></td>
<td class="org-left">the value of <code>#+NAME:</code></td>
</tr>

<tr>
<td class="org-left"><code>{{{property(NAME)}}}</code></td>
<td class="org-left">a property of the current heading</td>
</tr>

<tr>
<td class="org-left"><code>{{{n}}}</code>, <code>{{{n(name)}}}</code></td>
<td class="org-left">a counter (per name), <code>n(name,-)</code> repeats</td>
</tr>

<tr>
<td class="org-left"><code>{{{results(x)}}}</code></td>
<td class="org-left">how inline babel results are wrapped</td>
</tr>
</tbody>
</table>

Your config can define global ones: `export = { global_macros = { ... } }`
(strings, or Lua functions receiving the arguments).


<a id="orgb33855c"></a>

## Sample: macros

Hello, world!  two before one.
This is "Export: hands-on examples" by org.nvim examples, exported from 19-export.org.
Step 1, step 2, step 3; again step 3.
Press <kbd>C-c C-e</kbd>.


<a id="org1fa24c4"></a>

### Owned part

This part is owned by Charles.


<a id="org99b8178"></a>

## Exercises: macros

**Try:** `<prefix>e s b t A`.

**Expect:**

    Hello, world!  two before one.  This is "Export: hands-on examples" by
    org.nvim examples, exported from 19-export.org.  Step 1, step 2, step 3;
    again step 3.  Press .
    
    
    Owned part
    ==========
    
      This part is owned by Charles.

Things to notice:

-   `{{{title}}}` and `{{{author}}}` are the file's `#+TITLE:` and
    `#+AUTHOR:`, not the sample's `EXPORT_TITLE` (Emacs does the same).
-   The `kbd` macro produced nothing in plain text: it expands to an HTML
    export snippet (next section). With `<prefix>e s b h H` the line reads
    `Press <kbd>C-c C-e</kbd>.`
-   `{{{property(OWNER)}}}` reads the heading it is written under. Text
    right under the exported heading reads that heading's own drawer: in the
    sample, `{{{property(EXPORT_TITLE)}}}` would give `Macro demo`.

**Try:** add a line `{{{greet(Neovim\, again)}}}` to the sample and export:
`Hello, Neovim, again!` (the escaped comma is not an argument separator).


<a id="orgc1855ad"></a>

# Raw output for one back-end

Sometimes you want to write HTML or LaTeX directly. Three ways, all passed
through untouched to **their** back-end and dropped by all others:

-   export snippets inside a paragraph: `@@html:<mark>@@text@@html:</mark>@@`,
    `@@latex:\newpage@@`, `@@md:...@@`, `@@ascii:...@@`;
-   one-line keywords: `#+HTML: ...`, `#+LATEX: ...`, `#+ASCII: ...`,
    `#+MD: ...`, `#+ODT: ...`, `#+BEAMER: ...`, `#+TEXINFO: ...`;
-   export blocks: `#+begin_export html` &hellip; `#+end_export` (also `latex`,
    `md`, `ascii`, `odt`, &hellip;). Insert one with `<prefix>ib` (Emacs
    `C-c C-,`) then `h` (html), `l` (latex), `a` (ascii) or `E` (asks for
    the back-end); edit its content in a split with `<prefix>'`.


<a id="org63a82c9"></a>

## Sample: snippets and export blocks

This word is <mark>highlighted</mark> in HTML, emphasized in LaTeX.

<hr class="fancy" />

<div class="note">Only in HTML.</div>

The end.


<a id="org3855050"></a>

## Exercises: snippets and export blocks

**Try:** `<prefix>e s b h H`.

**Expect:** the HTML parts only:

    <p>
    This word is <mark>highlighted</mark> in HTML, emphasized in LaTeX.
    </p>
    <hr class="fancy" />
    <div class="note">Only in HTML.</div>
    <p>
    The end.
    </p>

**Try:** `<prefix>e s b t A`.

**Expect:** no markup at all, and the `ascii` block:

    This word is highlighted in HTML, emphasized in LaTeX.
    Only in plain text.
    The end.

**Try:** `<prefix>e s b l L`.

**Expect:** the LaTeX parts:

    This word is highlighted in HTML, \emph{emphasized} in LaTeX.
    \newpage
    \begin{center}Only in \LaTeX.\end{center}
    The end.


<a id="org42d1764"></a>

# HTML specifics: #+ATTR<sub>HTML</sub> and #+HTML<sub>HEAD</sub>

-   `#+ATTR_HTML: :class wide :style color: red` before a table, image,
    link-only paragraph, list or block adds those HTML attributes. For a
    link, the attributes go to the `<a>` (or `<img>`) element.
-   `#+HTML_HEAD:` and `#+HTML_HEAD_EXTRA:` add lines to `<head>` (CSS,
    meta tags); in a subtree use `EXPORT_HTML_HEAD`.
-   `#+HTML_DOCTYPE: html5` and `#+OPTIONS: html5-fancy:t` give HTML5
    elements (`<section>`, `<figure>`, &hellip;). `html-postamble:nil` removes
    the footer, `html-style:nil` the default CSS.
-   `#+HTML_LINK_HOME:` / `#+HTML_LINK_UP:` add navigation links,
    `#+HTML_CONTAINER:` changes the `div` around sections.

A file set up for HTML (example, not live):

    #+TITLE: Team page
    #+HTML_DOCTYPE: html5
    #+OPTIONS: html5-fancy:t html-postamble:nil toc:nil
    #+HTML_HEAD: <link rel="stylesheet" href="style.css" />
    #+HTML_HEAD_EXTRA: <meta name="theme-color" content="#336699" />


<a id="org7e9f4b5"></a>

## Sample: HTML attributes

<table id="team" border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides" class="wide">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Name</th>
<th scope="col" class="org-left">Role</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left">Ada</td>
<td class="org-left">analyst</td>
</tr>
</tbody>
</table>

[Neovim](https://neovim.io)

-   one
-   two


<a id="orgc998d61"></a>

## Exercises: HTML attributes

**Try:** `<prefix>e s h H`.

**Expect:** the style line at the end of `<head>`, and in the body:

    <style>.wide { width: 100%; }</style>
    </head>
    ...
    <table id="team" border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides" class="wide">
    ...
    <p target="_blank" title="Neovim home page">
    <a href="https://neovim.io" target="_blank" title="Neovim home page">Neovim</a>
    </p>
    
    <ul class="org-ul checklist">

The `:id` replaced the generated table id, the `:class` was added to the
default attributes (for lists, to the `org-ul` class). For a paragraph
holding only a link, the attributes land on both the `<p>` and the `<a>`,
exactly like Emacs. The page ends right after the content: no postamble
(`html-postamble:nil`).


<a id="org2580b9d"></a>

# LaTeX and PDF specifics

-   `#+LATEX_CLASS: article` (default), `report`, `book`, `beamer` &hellip; from
    `export.latex.classes`; `#+LATEX_CLASS_OPTIONS: [a4paper,11pt]`.
-   `#+LATEX_HEADER: \usepackage{xcolor}` adds preamble lines
    (`EXPORT_LATEX_HEADER` in a subtree); `#+LATEX_HEADER_EXTRA:` too.
-   `#+ATTR_LATEX:` before a table: `:environment longtable`, `:align
      l|r`, `:booktabs t`, `:float nil`, `:placement [H]`, `:caption`; before
    an image: `:width 0.5\textwidth`; before a list, `:options`.
-   LaTeX fragments (`$E=mc^2$`, `\(...\)`, `\begin{equation}`) pass through
    to LaTeX; HTML shows them with MathJax.
-   PDF (`l p`) writes the .tex file next to this one and runs `latexmk`
    (or `pdflatex` three times). Without a TeX installation you get an error
    message and only the .tex file.


<a id="org37dc0a3"></a>

## Sample: LaTeX attributes

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">
<caption class="t-above"><span class="table-number">Table 2:</span> Results</caption>

<colgroup>
<col  class="org-left" />

<col  class="org-right" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Test</th>
<th scope="col" class="org-right">Score</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left">A</td>
<td class="org-right">91</td>
</tr>
</tbody>
</table>

Inline math $a^2 + b^2 = c^2$ and a display:

\begin{equation}
e^{i\pi} + 1 = 0
\end{equation}


<a id="orgebd05b4"></a>

## Exercises: LaTeX attributes

**Try:** `<prefix>e s l L`.

**Expect:** the class, its options and the extra package in the preamble:

    \documentclass[a4paper]{report}
    ...
    \usepackage{booktabs}

and in the body a `table` float with `[h]`, the `lr` column spec and
booktabs rules:

    \begin{table}[h]
    \caption{Results}
    \centering
    \begin{tabular}{lr}
    \toprule
    Test & Score\\
    \midrule
    A & 91\\
    \bottomrule
    \end{tabular}
    \end{table}

The math is copied as it is. With the `report` class, level-1 headings
would be `\chapter` instead of `\section`.


<a id="orga657571"></a>

# Beamer slides

Beamer is LaTeX for presentations. By default level-1 headings are frames
(slides); `H:2` makes level 2 the frames and level 1 sections. Properties
refine it: `BEAMER_env` (`block`, `alertblock`, `example`, `columns`,
`column`, `note`, `ignoreheading`, &hellip;), `BEAMER_col` (column width),
`BEAMER_act` (overlay like `<2->`), `BEAMER_opt` (frame options).
`#+BEAMER_THEME:` (`EXPORT_BEAMER_THEME`) picks the theme. `l B` exports
to a buffer; `l P` makes a PDF (needs LaTeX).


<a id="org8b4ae79"></a>

## Sample: slides


<a id="orgb998a8e"></a>

### First slide

-   point one
-   point two


<a id="orgc16cabf"></a>

### Two columns

1.  Left

    Text on the left.

2.  Right

    Careful!


<a id="org8d32f2f"></a>

## Exercises: slides

**Try:** `<prefix>e s l B`.

**Expect:** a Beamer document with the theme, a title frame, then one frame
per level-1 heading of the sample:

    \documentclass[presentation]{beamer}
    ...
    \usetheme{Madrid}
    \author{Ada}
    \date{\today}
    \title{A tiny talk}
    ...
    \maketitle
    \begin{frame}[label={sec:orgcc50823}]{First slide}
    \begin{itemize}
    \item point one
    \item point two
    \end{itemize}
    \end{frame}
    \begin{frame}[label={sec:orgcd668b6}]{Two columns}
    \begin{columns}
    \begin{column}{0.5\columnwidth}
    Text on the left.
    \end{column}
    \begin{column}{0.5\columnwidth}
    \begin{alertblock}{Right}
    Careful!
    \end{alertblock}
    \end{column}
    \end{columns}
    \end{frame}


<a id="org5f1eceb"></a>

# Markdown, GFM, plain text and Org


<a id="org1153bb5"></a>

## Sample: a table and code everywhere

-   [X] done item
-   [ ] open item

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Tool</th>
<th scope="col" class="org-left">Needs</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left">md</td>
<td class="org-left">nothing</td>
</tr>
</tbody>
</table>

    print("hi")


<a id="org8414234"></a>

## Exercises: a table and code everywhere

**Try:** `<prefix>e s b m M` (plain Markdown).

**Expect:** Markdown has no table syntax, so the table is written as HTML;
the code block is indented by four spaces:

    -   [X] done item
    -   [ ] open item
    
    <table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">
    ...
        print("hi")

**Try:** `<prefix>e s b m G` (GitHub flavoured Markdown).

**Expect:** task-list items, a pipe table (not padded, which GitHub does
not need) and a fenced block with the language:

    - [x] done item
    - [ ] open item
    
    | Tool | Needs |
    |---|---|
    | md | nothing |
    
    ```python
    print("hi")
    ```

**Try:** `<prefix>e s b t A` (ASCII).

**Expect:**

    - [X] done item
    - [ ] open item
    
     Tool  Needs
    ---------------
     md    nothing
    
    ,----
    | print("hi")
    `----

**Try:** `<prefix>e s b t U` (UTF-8).

**Expect:** the same drawn with Unicode characters:

    • ☑ done item
    • ☐ open item
    
    ━━━━━━━━━━━━━━━
     Tool  Needs
    ───────────────
     md    nothing
    ━━━━━━━━━━━━━━━
    
    ┌────
    │ print("hi")
    └────

`t L` (Latin-1) sits in between: Latin-1 characters where they exist,
ASCII otherwise.

**Try:** `<prefix>e s b O O` (Org back-end).

**Expect:** the subtree comes back as Org, after macros, `#+INCLUDE` and
`noexport` have been processed (useful to see exactly what the other
back-ends receive). Note the code indented by two spaces, like Emacs:

    - [X] done item
    - [ ] open item
    
    | Tool | Needs   |
    |------+---------|
    | md   | nothing |
    
    #+begin_src python :exports code
      print("hi")
    #+end_src


<a id="org5b7a29e"></a>

# #+INCLUDE: pulling in other files

`#+INCLUDE: "file"` is replaced by the file's content on export (never in
the buffer). Variants:

-   `#+INCLUDE: "notes.org"`: an Org file; its headings are adjusted to the
    current level (`:minlevel N` to choose).
-   `#+INCLUDE: "notes.org::*Heading"`: one subtree; `::#custom-id` or
    `::name` also work; `:only-contents t` drops the heading line.
-   `#+INCLUDE: "init.lua" src lua`: as a source block; `example`,
    `export html` also work.
-   `:lines "5-10"` (or `"5-"`, `"-10"`) takes a line range (the end is
    exclusive, like Emacs: `"1-4"` is lines 1 to 3).


<a id="org5060a91"></a>

## Sample: include

The first lines of the bundled init file:

    -- Try org.nvim without touching your own config:
    --
    --   nvim -u examples/minimal_init.lua examples/tutorial.org

And a section of the tutorial:
Export options go in `#+OPTIONS:` at the top of a file, for example
`#+OPTIONS: toc:2 num:nil ^:{} todo:nil`. `#+TITLE:`, `#+AUTHOR:` and


<a id="org2d522f4"></a>

## Exercises: include

**Try:** `<prefix>e s b m M`.

**Expect:** the three comment lines of `minimal_init.lua` as a code block,
followed by the first two lines of the tutorial's "Export settings"
section:

    The first lines of the bundled init file:
    
        -- Try org.nvim without touching your own config:
        --
        --   nvim -u examples/minimal_init.lua examples/tutorial.org
    
    And a section of the tutorial:
    Export options go in `#+OPTIONS:` at the top of a file, for example
    `#+OPTIONS: toc:2 num:nil ^:{} todo:nil`. `#+TITLE:`, `#+AUTHOR:` and

`#+SETUPFILE: "other.org"` is related: it reads the settings keywords
(`#+OPTIONS`, `#+MACRO`, `#+TODO`, &hellip;) of another file.


<a id="org617150d"></a>

# Source blocks and :exports

The `:exports` header argument decides what a code block contributes:

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left"><code>:exports</code></th>
<th scope="col" class="org-left">Exported</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>code</code></td>
<td class="org-left">the code only (default for most languages)</td>
</tr>

<tr>
<td class="org-left"><code>results</code></td>
<td class="org-left">the result only</td>
</tr>

<tr>
<td class="org-left"><code>both</code></td>
<td class="org-left">code, then result</td>
</tr>

<tr>
<td class="org-left"><code>none</code></td>
<td class="org-left">nothing</td>
</tr>
</tbody>
</table>

With `babel.evaluate_on_export = true` (the default) blocks exporting
`results` or `both` are **run again** during export, in a copy of the buffer
(the buffer itself is not changed), after the usual "Evaluate?"
confirmation. `:eval never-export` (or `no-export`) keeps the `#+RESULTS:`
already in the buffer instead. More in [17-babel.org](17-babel.md).


<a id="orgeb4a2da"></a>

## Sample: exports

    (+ 1 2)

    (* 6 7)

    (concat "org" "." "nvim")

    (message "invisible")

    (* 100 100)

    stale value kept on export

The answer is `(* 6 7)`.


<a id="orgf7db64b"></a>

## Exercises: exports

**Try:** `<prefix>e s b t A`. You are asked "Evaluate this emacs-lisp code
block on your system?" three times (the `results` block, the `both` block
and the inline `src_` call): answer `y` each time. (Emacs Lisp runs in
`emacs --batch` when Emacs is installed, otherwise on org.nvim's own Lisp
interpreter, which handles these simple expressions.)

**Expect:** code and results in the text back-end's boxes; the inline
result is verbatim (`` `42' ``):

    ,----
    | (+ 1 2)
    `----
    
    ,----
    | 42
    `----
    
    ,----
    | (concat "org" "." "nvim")
    `----
    
    ,----
    | org.nvim
    `----
    
    ,----
    | stale value kept on export
    `----
    
    The answer is `42'.

The `:exports none` block is absent, and the `never-export` block shows
its old `#+RESULTS:` instead of `10000`. The buffer is not modified: no
`#+RESULTS:` was added under the other blocks.

**Try:** export again and answer `n` to every question: the `results`
blocks then export nothing (they have no `#+RESULTS:` in the buffer), the
`both` block only its code, and the inline call is left empty.


<a id="org4554367"></a>

# Citations

Citations are written `[cite:@key]` (styles: `[cite/t:@key]` text,
`[cite/a:@key]` author, `[cite/na:@key]` no author, &hellip;; prefixes and
suffixes: `[cite:see @key p. 3]`). `#+BIBLIOGRAPHY:` names a .bib or
CSL-JSON file and `#+PRINT_BIBLIOGRAPHY:` prints the list. The "basic"
processor works with every back-end; LaTeX can use `natbib`, `biblatex` or
`bibtex` with `#+CITE_EXPORT:`. CSL styles (citeproc) are not supported;
for those, export to Org or Markdown and run `pandoc --citeproc`.

This file's header has `#+BIBLIOGRAPHY: ../tests/fixtures/export/cite/refs.bib`
(a test fixture of the repo).


<a id="orgaa5f503"></a>

## Sample: citations

As shown before (Doe, John and Smith, Jane, 2020), and in a book (see Zed, Anna, 2019 p. 3).
Alpha, Bob (2018) wrote a thesis.

Alpha, Bob (2018). *Thesis*, Univ.

Doe, John and Smith, Jane (2020). *On the TeXbook and $\alpha$ &alpha; things*, Journal of Tests.

Zed, Anna (2019). *A Book of Strings*, ACME Press.


<a id="org447f95a"></a>

## Exercises: citations

**Try:** `<prefix>e s b t A`.

**Expect:** author-year citations, and the bibliography sorted by author
where `#+PRINT_BIBLIOGRAPHY:` is:

    As shown before (Doe, John and Smith, Jane, 2020), and in a book (see
    Zed, Anna, 2019 p. 3).  Alpha, Bob (2018) wrote a thesis.
    
    Alpha, Bob (2018). /Thesis/, Univ.
    
    Doe, John and Smith, Jane (2020). /On the TeXbook and $\alpha$ alpha
    things/, Journal of Tests.
    
    Zed, Anna (2019). /A Book of Strings/, ACME Press.

**Try:** `<prefix>e s b h H`: the same text in `<p>` elements, with the
titles in `<i>` and the `$\alpha$` of the .bib title as MathJax
`\(\alpha\)`.

**Try:** change `[cite:@doe2020]` to `[cite/na:@doe2020]` (no author):
`As shown before (2020)`. And `[cite:see @zed2019 p. 3]` to
`[cite/nb:@zed2019]` (numeric): `in a book (3)`, the entry's position in
the bibliography.


<a id="org0acc137"></a>

# Broken links

A link that points nowhere (`[[*No such heading]]`) stops the export with
an error by default: better than a silently dead link.
`#+OPTIONS: broken-links:mark` writes `[BROKEN LINK: ...]` instead, and
`broken-links:t` drops the link. This file sets `broken-links:mark` at
the top so that a whole-file export works despite the sample below.


<a id="org72f1af6"></a>

## Sample: broken links

This points to [BROKEN LINK: \*A heading that does not exist].


<a id="org6730c51"></a>

## Exercises: broken links

**Try:** `<prefix>e s b t A`.

**Expect:** `This points to [BROKEN LINK: *A heading that does not exist].`

**Try:** change `broken-links:mark` to `broken-links:nil` in
`EXPORT_OPTIONS` and export again. No buffer opens; instead:

    Export failed: Org export aborted.  Unable to resolve link: "*A heading that does not exist"
    See export.with_broken_links (org-export-with-broken-links)

**Try:** `broken-links:t`: the link simply disappears (`This points to .`).


<a id="org0373b60"></a>

# iCalendar, ODT, DOCX, Texinfo and pandoc (file exports)

These write files; there is no buffer variant. If you try them here, the
files land in `examples/` (delete them afterwards).

-   iCalendar (`c f`): every entry with an active timestamp, SCHEDULED or
    DEADLINE becomes a VEVENT (and TODOs a VTODO with
    `export.icalendar.include_todo`). `c a` writes one .ics per agenda file,
    `c c` combines them into `export.icalendar.combined_agenda_file`
    (`~/org.ics` by default, outside the repo).
-   ODT (`o o`): a real OpenDocument file written in pure Lua; opens in
    LibreOffice, Word, Google Docs. `export.odt.preferred_output_format =
      "docx"` converts it with LibreOffice.
-   DOCX (`d d`) and other formats (`p`, then e.g. `rst`, `epub`, `typst`):
    pandoc converts the Org back-end's output. The file is always named
    after the Org file (`examples/19-export.docx`), even in a subtree with
    `EXPORT_FILE_NAME`.
-   Texinfo (`i t`) writes a .texi manual; `i i` also runs `makeinfo`.


<a id="org537a46d"></a>

## Sample: calendar entries


<a id="org3a82934"></a>

### Team meeting

<span class="timestamp-wrapper"><span class="timestamp">&lt;2026-10-07 Wed 10:00-11:00&gt;</span></span>


<a id="orgedc1d8f"></a>

### Submit the report


<a id="org9fdb3b0"></a>

## Exercises: calendar entries

**Try (writes examples/19-export.ics):** `<prefix>e c f`. The dispatcher's
iCalendar entries always export the **whole file**, so the three
"Evaluate?" questions of the `:exports` sample come up again: answer `n`.
Open the file with `:e examples/19-export.ics`.

**Expect:** among others

    BEGIN:VEVENT
    DTSTART:20261007T100000
    DTEND:20261007T110000
    SUMMARY:Team meeting
    ...
    BEGIN:VEVENT
    DTSTART;VALUE=DATE:20261015
    DTEND;VALUE=DATE:20261016
    SUMMARY:DL: Submit the report

and an event for `<2026-10-05 Mon>` of the "Ship the release" sample. A
TODO entry's deadline becomes a VTODO only with
`export.icalendar.include_todo`; that is why "Submit the report" has no
TODO keyword. Afterwards: `:!rm examples/19-export.ics`.

**Try (writes examples/19-export.odt):** `<prefix>e s o o`, open the file in
LibreOffice (or `<prefix>e s o O` to open it right away), then delete it.


<a id="orge3c0000"></a>

# Hugo blog posts (the hugo extension)

The `hugo` extension (a port of Emacs ox-hugo, off by default) writes
Markdown for the Hugo static site generator. Turn it on in your config:

    require("org").setup({ extensions = { hugo = true } })

A heading with an `EXPORT_FILE_NAME` property is one post; its children are
the post's sections, and it inherits `EXPORT_HUGO_*` properties (section,
base dir, front matter format, &hellip;) from its parents. The dispatcher entry
is `H`: `H t` shows the post in a buffer, `H H` writes the post at the
cursor to `<base dir>/content/<section>/<name>.md`, `H A` writes every
post of the file. Without such headings, the whole file is one post
(`#+title`, `#+hugo_base_dir`, `#+hugo_section` keywords).


<a id="orgdc74bcd"></a>

## DONE Sample: a Hugo post     :emacs:@notes:

Hello from *Org*.


<a id="org36bb00b"></a>

### A section

With a footnote<sup><a id="fnr.hugo" class="footref" href="#fn.hugo" role="doc-backlink">5</a></sup>.


<a id="orgbda6d3b"></a>

## Exercises: a Hugo post

**Try:** with the extension on, put the cursor in the sample above and press
`<prefix>e H t` (to a temporary buffer).

**Expect:** a Markdown buffer whose front matter comes from the heading:
the CLOSED date, the tags (`@notes` is a category), `draft = false`
because the heading is DONE, and the custom front matter:

    +++
    title = "Sample: a Hugo post"
    author = ["org.nvim examples"]
    date = 2026-10-05T10:30:00+00:00
    tags = ["emacs"]
    categories = ["notes"]
    draft = false
    featured = true
    +++
    
    Hello from _Org_.
    
    
    ## A section {#a-section}
    
    With a footnote[^fn:1].
    
    [^fn:1]: Footnotes go to the end of the post.

(The date shows your time zone's offset.) Change `DONE` to `TODO`: the
post becomes a draft. Add `:EXPORT_HUGO_FRONT_MATTER_FORMAT: yaml` to the
drawer and export again: the front matter is YAML between `---` lines.

**Try (writes under /tmp):** `<prefix>e H H`. The post goes to
`/tmp/org-nvim-hugo-site/content/blog/my-first-post.md`; see
`:h org-extensions-hugo` for page bundles, images and links between posts.


<a id="org254b633"></a>

# Publishing projects

Publishing exports whole directories at once (a website, a set of PDFs):
projects are set in your config under `export.publish.projects`, and only
files changed since the last run are exported again. Dispatcher: `P f`
(this file), `P p` (its project), `P x` (choose one), `P a` (all). The
commands are `:Org publish`, `:Org publish NAME`, `:Org publish all
force` (`force` re-exports even unchanged files).

This is configuration, not something to run from here:

    require("org").setup({
      export = {
        publish = {
          projects = {
            notes = {
              base_directory = "~/org/site",   -- the .org sources
              base_extension = "org",
              publishing_directory = "~/public_html",
              publishing_function = "html",    -- or "pdf", "md", "org", ...
              recursive = true,
              exclude = "^drafts/",            -- Vim regex, relative path
              auto_sitemap = true,             -- writes sitemap.org + .html
              sitemap_title = "My notes",
              with_toc = false,                -- any export option
              html_postamble = false,
            },
            static = {
              base_directory = "~/org/site",
              base_extension = "css\\|png\\|jpg",
              publishing_directory = "~/public_html",
              recursive = true,
              publishing_function = "attachment", -- copy as is
            },
            site = { components = { "notes", "static" } },
          },
        },
      },
    })

Then `:Org publish site` builds both. The timestamps of published files
are kept in `export.publish.timestamp_directory`.

**Try:** `<prefix>e P x`: with the bundled init no project is configured, so
the prompt offers nothing to choose; press `<Esc>`.


<a id="org8185bc2"></a>

# Configuring defaults

Every `#+OPTIONS` key has a config default under `export`, named after the
Emacs variable: `with_toc`, `with_section_numbers`, `headline_levels`,
`with_tags`, `with_todo_keywords`, `with_priority`, `with_drawers`,
`with_properties`, `with_broken_links`, `select_tags`, `exclude_tags`,
`author`, `email`, &hellip; and per back-end tables (`export.html`,
`export.latex`, `export.md`, `export.ascii`, `export.odt`, &hellip;).

    require("org").setup({
      export = {
        output_dir = "~/exports",       -- instead of next to the source file
        open_after_export = false,      -- open every exported file
        with_toc = false,
        with_section_numbers = false,
        author = "Ada Lovelace",
        global_macros = { year = function() return os.date("%Y") end },
        html = { doctype = "html5", html5_fancy = true },
        ascii = { charset = "utf-8", text_width = 80 },
        md = { headline_style = "atx" },
      },
    })

Filters and hooks (`export.filters`, `export.hooks`) run Lua functions on
the text or the lines before parsing: see `:h org-export`.


<a id="orgce04e31"></a>

# Further reading

-   `:h org-export` (dispatcher, command and Lua API)
-   `:h org-export-settings` (keywords, `#+OPTIONS`, macros, `#+INCLUDE`)
-   `:h org-export-backends`, `:h org-export-ascii`, `:h org-export-beamer`,
    `:h org-export-odt`, `:h org-export-texinfo`, `:h org-export-icalendar`
-   `:h org-export-cite` (citations), `:h org-publish`
-   `:h org-export-unsupported` (what needs Emacs)
-   Related example files: [17-babel.org](17-babel.md) (code
    blocks), [14-footnotes.org](14-footnotes.md),
    [13-links.org](13-links.md) (link types),
    [21-images-latex.org](21-images-latex.md) (images and LaTeX
    fragments), and the overview in [00-index.org](00-index.md).


# Footnotes

<sup><a id="fn.1" href="#fnr.1">1</a></sup> Une note de bas de page.

<sup><a id="fn.2" href="#fnr.2">2</a></sup> Not exported with f:nil.

<sup><a id="fn.3" href="#fnr.3">3</a></sup> The definition of the named note.

<sup><a id="fn.4" href="#fnr.4">4</a></sup> Defined right here.

<sup><a id="fn.5" href="#fnr.5">5</a></sup> Footnotes go to the end of the post.
