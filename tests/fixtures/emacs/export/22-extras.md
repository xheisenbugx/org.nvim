
# Table of Contents

1.  [How to use this file](#org9627784)
    1.  [Keys in this file](#org8463113)
2.  [Getting help inside Neovim](#orgbdb4163)
    1.  [g?: the keys of the current buffer](#org2fc59bc)
    2.  [:Org: every command by name](#orge87d85b)
    3.  [:help](#org99371d7)
3.  [Checking your setup: :checkhealth org](#orgd1986c9)
4.  [Completion](#org97668aa)
    1.  [What completes where](#org22e105b)
    2.  [Practice area](#org15303e2)
        1.  [Tags and TODO keywords](#org38bae4b)
        2.  [Properties](#orgefbd59a)
5.  [Structure templates and org-tempo](#orge5cb850)
    1.  [<prefix>ib: insert a block](#orgd42c180)
    2.  [org-tempo: <s<Tab>](#orgd54f3f3)
6.  [Special edit buffers: <prefix>'](#org8f24d88)
    1.  [Examples to edit](#orgc0d11a5)
    2.  [Narrowing is the same idea](#org73cb48e)
7.  [Elements: paragraphs, lists, blocks, tables &hellip;](#org29e3bf9)
    1.  [Practice](#org26715ee)
8.  [Speed keys](#orgd57504c)
    1.  [Practice](#org0c92d11)
        1.  [Speed one](#orgb08c2e4)
        2.  [Speed two](#orge6bfee2)
        3.  [Speed three](#org45cb940)
9.  [Inline tasks](#org14f7a8f)
    1.  [Practice](#orgb6725e2)
        1.  [Kitchen](#org4dafb16)
10. [Encryption: org-crypt](#org6063be0)
    1.  [Practice](#orgfd896ea)
        1.  [Wifi password](#org9c43852):crypt:
11. [Display options](#org0f736aa)
12. [Setup files: #+SETUPFILE](#orgd22997b)
13. [org-lint: check the syntax](#extras-lint)
14. [Emacs keys](#orge018dd6)
        1.  [Emacs practice](#org6669e35)
15. [Integrations](#org8bc0a05)
    1.  [org-protocol: capture from the browser](#org0373b60)
    2.  [RSS and Atom feeds](#org8185bc2)
    3.  [MobileOrg](#orgce04e31)
    4.  [The Lua API](#org4cefeec)
16. [Further reading](#org2a5f35e)



<a id="org9627784"></a>

# How to use this file

This file collects the features of org.nvim that don't belong to one of the
other example files: finding help, completion, the syntax checker
(org-lint), speed keys, inline tasks, encryption, special edit buffers,
element commands, structure templates, display options, setup files, the
Emacs keys, and the integrations (org-protocol, feeds, MobileOrg, the Lua
API).

-   The file starts folded (`#+STARTUP: overview`). Put the cursor on a
    heading and press `<Tab>` to open it; `<S-Tab>` cycles the whole buffer.
-   Nothing breaks if you make a mess: `u` undoes, and
    `git checkout examples/22-extras.org` restores the file.
-   `g?` lists every key of the buffer (see the next section).
-   `<prefix>` means `<leader>o`, the default `mappings.prefix`. With
    `examples/minimal_init.lua` the leader is `<Space>`, so `<prefix>'` is
    `<Space>o'`.
-   Lines starting with **Try:** are exercises with the exact keys to press;
    **Expect:** says what you should see afterwards.
-   Lines starting with `#` followed by a space are Org comments that annotate
    the examples. They are dimmed and never exported.

Start Neovim from the repository root with the bundled init file, so your
own config is not involved:

    nvim -u examples/minimal_init.lua examples/22-extras.org

`examples/minimal_init.lua` sets the leader keys (`<Space>` and `\`),
points the agenda at `examples/*.org`, sends captures to a scratch
`org_directory` under `stdpath("state")`, and defines a few capture
templates and custom agenda commands. Everything this file talks about is
left at its default, so several sections show how to turn a feature on
for the current session with a `:lua` command. Those changes last until
you quit Neovim.


<a id="org8463113"></a>

## Keys in this file

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Key</th>
<th scope="col" class="org-left">Emacs key</th>
<th scope="col" class="org-left">What it does</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>g?</code></td>
<td class="org-left">&nbsp;</td>
<td class="org-left">list the keys of the buffer</td>
</tr>

<tr>
<td class="org-left"><code>:Org</code></td>
<td class="org-left">&nbsp;</td>
<td class="org-left">pick any org command</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-x&gt;&lt;C-o&gt;</code></td>
<td class="org-left"><code>M-TAB</code></td>
<td class="org-left">complete (Insert mode)</td>
</tr>

<tr>
<td class="org-left"><code>:Org lint</code></td>
<td class="org-left"><code>M-x org-lint</code></td>
<td class="org-left">check the syntax of the buffer</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;'</code></td>
<td class="org-left"><code>C-c '</code></td>
<td class="org-left">edit in a separate buffer</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;ib</code></td>
<td class="org-left"><code>C-c C-,</code></td>
<td class="org-left">insert a <code>#+begin_</code> block</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;v</code></td>
<td class="org-left"><code>M-h</code></td>
<td class="org-left">select the element</td>
</tr>

<tr>
<td class="org-left"><code>&lt;M-}&gt;</code> / <code>&lt;M-{&gt;</code></td>
<td class="org-left"><code>M-}</code> / <code>M-{</code></td>
<td class="org-left">next / previous element</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-M-t&gt;</code></td>
<td class="org-left"><code>C-M-t</code></td>
<td class="org-left">swap with the previous element</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-c&gt;:</code></td>
<td class="org-left"><code>C-c :</code></td>
<td class="org-left">toggle fixed-width <code>:</code> lines</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-c&gt;&lt;C-x&gt;t</code></td>
<td class="org-left"><code>C-c C-x t</code></td>
<td class="org-left">insert an inline task</td>
</tr>

<tr>
<td class="org-left"><code>:Org num_mode</code></td>
<td class="org-left"><code>M-x org-num-mode</code></td>
<td class="org-left">number the headlines</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-c&gt;&lt;C-x&gt;\</code></td>
<td class="org-left"><code>C-c C-x \</code></td>
<td class="org-left">toggle pretty entities</td>
</tr>

<tr>
<td class="org-left"><code>:checkhealth org</code></td>
<td class="org-left">&nbsp;</td>
<td class="org-left">check the setup</td>
</tr>
</tbody>
</table>


<a id="orgbdb4163"></a>

# Getting help inside Neovim

You never need to leave Neovim to find a key or a command.


<a id="org2fc59bc"></a>

## g?: the keys of the current buffer

`g?` in an org buffer (or in the agenda) opens a floating window listing
every mapping of that buffer, grouped by topic ("Anywhere", "Structure",
"Links" &hellip;). Each row lists every key of one command (the Vim-style key,
the `<prefix>` key and the Emacs key) and what it does. `i_` marks
Insert-mode keys.

In the window:

-   `/` searches the list like any buffer,
-   `{` and `}` jump between sections,
-   `q`, `<Esc>` or `g?` close it.

**Try:** press `g?` here, then type `/Footnote:` and `<CR>`.
**Expect:** the cursor lands on the row
`<leader>oif  <C-c><C-x>f  Footnote: jump / new / menu (count)`.
Press `q` to close the window.

**Try:** press `g?`, then `}` a few times.
**Expect:** the cursor jumps from one section heading to the next.


<a id="orge87d85b"></a>

## :Org: every command by name

Every action of org.nvim has a name (the names in `:h org-keymaps`), and
`:Org {name}` runs it, whether or not it has a key:

-   `:Org` alone shows a picker with every command and its description.
-   `:Org <Tab>` completes the names on the command line.
-   Some commands take arguments: `:Org agenda a`, `:Org capture t`,
    `:Org export html`, `:Org lint duplicate-name`, `:Org timer_countdown 5`.
-   Some take a range, e.g. `:'<,'>Org link_preview` previews the image
    links of the Visual selection.

**Try:** type `:Org` and `<CR>`, then type `num` to filter the list and pick
`num_mode`.
**Expect:** every headline of this file gets a number in front of it
(`1`, `2`, `2.1` &hellip;). Run `:Org num_mode` again to remove them.

**Try:** type `:Org toggle_` and press `<Tab>` repeatedly.
**Expect:** the command line cycles through `toggle_archive_tag`,
`toggle_checkbox`, `toggle_comment` and the other `toggle_...` commands.


<a id="org99371d7"></a>

## :help

The manual is `:h org`. Every section has a tag, and most tags are named
after the Emacs feature: `:h org-links`, `:h org-lint`, `:h org-crypt`,
`:h org-speed-commands`, `:h org-emacs-keys`, `:h org-differences`.
`:h org-keymaps` lists every action with its default key, and
`:h org-config` every option.

**Try:** `:h org-differences` and read the part about the element commands.


<a id="orgd1986c9"></a>

# Checking your setup: :checkhealth org

`:checkhealth org` checks everything org.nvim depends on and prints what
it found, in five parts:

-   **org.nvim:** Neovim version, `org_directory`, agenda files, notes file, TODO
    keywords
-   **external tools:** pandoc, makeinfo, LaTeX, and the interpreter of every
    Babel language
-   **image and LaTeX previews:** which image backend draws previews (see
    [21-images-latex](21-images-latex.md))
-   **completion:** omnifunc, blink.cmp or nvim-cmp
-   **terminal keys:** whether tmux and the terminal pass the keys org maps

The last part matters more than it seems: keys such as `<C-CR>`, `<S-CR>`,
`<C-,>`, `<M-S-CR>` only reach Neovim when the terminal sends "extended
keys" (CSI u). Inside tmux you need `set -s extended-keys on` and a
`terminal-features` entry with `extkeys`. The check also reads the
keybinds of Ghostty, kitty and WezTerm and warns when one of them takes a
key org.nvim maps (Ghostty's `ctrl+tab`, kitty's `ctrl+shift+enter`, &hellip;).
On macOS, Option must send Alt for the `<M-...>` keys.

**Try:** run `:checkhealth org`.
**Expect:** a line "OK N agenda file(s) found" (the `.org` files of
`examples/` plus those in the scratch directory), one line per Babel
language saying whether its interpreter was found, and a "terminal keys"
part listing the keys that need CSI u.

If a key does nothing, test it: in Insert mode press `<C-v>` and then the
key. Neovim inserts what it received: `<C-CR>` should give `<C-CR>`, not
a plain `^M`.


<a id="org97668aa"></a>

# Completion

org.nvim completes Org syntax as you type, like Emacs `org-pcomplete`
(`M-TAB`). The same candidates are available three ways:

-   the built-in omnifunc, `<C-x><C-o>` in Insert mode. It is set
    automatically in every org buffer, nothing to configure;
-   a [blink.cmp](https://github.com/Saghen/blink.cmp) source;
-   an [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) source.

The blink.cmp source, in your blink.cmp options:

    sources = {
      per_filetype = { org = { inherit_defaults = true, "org" } },
      providers = { org = { name = "Org", module = "org.completion.blink" } },
    }

The nvim-cmp source:

    require("cmp").register_source("org", require("org.completion.cmp").new())
    -- and add { name = "org" } to the sources of cmp.setup.filetype("org", ...)


<a id="org22e105b"></a>

## What completes where

You type &hellip; and it completes:

-   **stars and a space:** TODO keywords, and `COMMENT`
-   **`:` after a headline title:** tags of the file and `#+TAGS`, not those
    already on the headline
-   **`#+`:** keywords: `TITLE:`, `STARTUP:`, `BEGIN_SRC` &hellip;
-   **`#+STARTUP:` and a space:** startup words: `overview`, `indent`, `num` &hellip;
-   **`#+OPTIONS:` and a space:** export options: `toc:`, `num:`, `^:` &hellip;
-   **`#+FILETAGS: :`:** tags
-   **`#+begin_src` and a space:** languages
-   **`#+begin_src lua :` or `#+HEADER: :`:** header arguments (`:results`, `:var`
    &hellip;)
-   **`#+BEGIN: clocktable :`:** clock table parameters
-   **`\`:** entities: `\alpha`, `\rarr` &hellip;
-   **`:` at line start in a property drawer:** property names the entry doesn't
    have yet
-   **`:` at line start elsewhere:** drawer names (`PROPERTIES:`, `LOGBOOK:` &hellip;)
-   **`[[`:** link types, stored links, abbreviations, headlines
-   **`[[*`:** headlines of the buffer
-   **`[[#`:** `CUSTOM_ID` values of the buffer

With the omnifunc, what you already typed filters the list: `#+ST` then
`<C-x><C-o>` offers only `STARTUP:`. Keywords are offered in the case you
typed (`#+st` gives `startup:`).


<a id="org15303e2"></a>

## Practice area

**Try:** on the empty line below, type `#+STA` then `<C-x><C-o>`.

**Expect:** `#+STA` becomes `#+STARTUP:` (the only match). Then type a space
and `<C-x><C-o>` again: a menu of startup words (`fold`, `overview`,
`nofold` &hellip;). Delete the line afterwards (`dd`).

**Try:** on the empty line below, type `#+begin_src l` then `<C-x><C-o>`.

**Expect:** a menu with `latex`, `lisp` and `lua`, the
languages starting with "l". Pick `lua`, type a space and `:ex` then
`<C-x><C-o>`: `:exports` is offered.

**Try:** on the empty line below, type `[[*Comp` then `<C-x><C-o>`.

**Expect:** `[[*Completion` (the heading of this section). Finish the link
with `]]` and press `<Esc>`, then `<CR>` on it: the cursor jumps to
"\* Completion".

**Try:** on the empty line below, type `[[#` then `<C-x><C-o>`.

**Expect:** the `CUSTOM_ID` values of this file: `#extras-lint` (the lint
section further down) and `#same-id` twice (from the intentionally broken
lint playground).

**Try:** on the empty line below, type `\alp` then `<C-x><C-o>`.

**Expect:** `\Alpha` and `\alpha` (the omnifunc ignores case when it
filters). With pretty entities on (see "Display options") they show as Α
and α.


<a id="org38bae4b"></a>

### Tags and TODO keywords

**Try:** put the cursor at the end of the headline "Tag practice" below
(`$`), press `a`, type a space, `:` and `<C-x><C-o>`.
**Expect:** the menu offers `crypt:`, `home:` and `urgent:`, but not
`work:`, which the headline already has.

**Try:** on the headline "Keyword practice", put the cursor on the K of
"Keyword", press `i` and then `<C-x><C-o>`.
**Expect:** `TODO`, `DONE` and `COMMENT`. Pick `TODO` and type a space: the
headline now reads "TODO Keyword practice".

1.  Tag practice     :work:

2.  Keyword practice


<a id="orgefbd59a"></a>

### Properties

**Try:** put the cursor on the `:Effort:` line of the drawer below, press
`o` to open a new line in the drawer, type `:` and `<C-x><C-o>`.
**Expect:** property names such as `ID:`, `CUSTOM_ID:`, `CATEGORY:`,
`ORDERED:` &hellip; but not `Effort:`, which this entry already has. Delete
the line when done.

1.  Property practice


<a id="orge5cb850"></a>

# Structure templates and org-tempo

Blocks (`#+begin_src`, `#+begin_quote` &hellip;) are tedious to type. Two
helpers insert them.


<a id="orgd42c180"></a>

## <prefix>ib: insert a block

`<prefix>ib` (Emacs `C-c C-,`, org-insert-structure-template) asks for a
block type and inserts an empty block at the cursor, or wraps the Visual
selection in one. The cursor goes inside the block, or right after
`#+begin_src` and a space so you can type the language. The keys come from
`structure_template_alist`:

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Key</th>
<th scope="col" class="org-left">Block</th>
<th scope="col" class="org-left">Key</th>
<th scope="col" class="org-left">Block</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>a</code></td>
<td class="org-left"><code>#+begin_export ascii</code></td>
<td class="org-left"><code>l</code></td>
<td class="org-left"><code>#+begin_export latex</code></td>
</tr>

<tr>
<td class="org-left"><code>c</code></td>
<td class="org-left"><code>#+begin_center</code></td>
<td class="org-left"><code>q</code></td>
<td class="org-left"><code>#+begin_quote</code></td>
</tr>

<tr>
<td class="org-left"><code>C</code></td>
<td class="org-left"><code>#+begin_comment</code></td>
<td class="org-left"><code>s</code></td>
<td class="org-left"><code>#+begin_src</code></td>
</tr>

<tr>
<td class="org-left"><code>e</code></td>
<td class="org-left"><code>#+begin_example</code></td>
<td class="org-left"><code>v</code></td>
<td class="org-left"><code>#+begin_verse</code></td>
</tr>

<tr>
<td class="org-left"><code>E</code></td>
<td class="org-left"><code>#+begin_export</code></td>
<td class="org-left"><code>h</code></td>
<td class="org-left"><code>#+begin_export html</code></td>
</tr>
</tbody>
</table>

`<Tab>` in the menu asks for any type by name (a custom block such as
`#+begin_note` too). Emacs writes that one in upper case
(`#+BEGIN_NOTE`), and so does org.nvim.

**Try:** select the two lines of the poem below with `V j`, press
`<prefix>ib` and then `v`.
**Expect:** the lines are wrapped:

    #+begin_verse
    Roses are red,
    violets are blue.
    #+end_verse

Roses are red,
violets are blue.

**Try:** on the empty line right after this paragraph (just before the
next heading), press `<prefix>ib` then `s`, type `lua` and `<Esc>`.
**Expect:** the empty line becomes an empty `#+begin_src lua` /
`#+end_src` block: after `s` the cursor waited right after
`#+begin_src` and a space, so what you typed became the language.


<a id="orgd54f3f3"></a>

## org-tempo: <s<Tab>

With `tempo = true` (the Emacs org-tempo module, off by default), typing
`<` plus a key of the table above and then `<Tab>` in Insert mode, alone
on a line, expands to the block. `<L`, `<H`, `<A` and `<i` expand to
the keywords `#+latex:`, `#+html:`, `#+ascii:` and `#+index:`, and
`<I` asks for a file to `#+include:`.

**Try:** turn it on for this session:

    :lua require("org.config").opts.tempo = true

Then on the empty line below press `i`, type `<q` and `<Tab>`.

**Expect:** `<q` is replaced by

    #+begin_quote
    #+end_quote

with the cursor on the empty line between them, still in Insert mode.

**Try:** on another empty line, `i`, `<L`, `<Tab>`, then type `\newpage`.
**Expect:** the line reads `#+latex: \newpage`.


<a id="org8f24d88"></a>

# Special edit buffers: <prefix>'

`<prefix>'` (Emacs `C-c '`, org-edit-special) opens the element at the
cursor in a separate buffer with the right filetype, so you get the
syntax, indentation and LSP of that language. Save it back:

-   `<prefix>'` (or `<C-c>'`) in the edit buffer saves and closes it,
-   `:w` saves without closing,
-   `<C-c><C-k>` throws the changes away (the `edit_src.abort` key).

It works on:

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">At the cursor</th>
<th scope="col" class="org-left">You edit</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left">a <code>#+begin_src LANG</code> block</td>
<td class="org-left">the code, filetype <code>LANG</code></td>
</tr>

<tr>
<td class="org-left">an inline <code>src_LANG{...}</code> block</td>
<td class="org-left">the code, kept on one line</td>
</tr>

<tr>
<td class="org-left">a <code>#+begin_example</code> block</td>
<td class="org-left">the text</td>
</tr>

<tr>
<td class="org-left">a <code>#+begin_export html</code> block</td>
<td class="org-left">the text, filetype <code>html</code></td>
</tr>

<tr>
<td class="org-left">a <code>#+begin_comment</code> block</td>
<td class="org-left">the text</td>
</tr>

<tr>
<td class="org-left"><code>:</code> fixed-width lines</td>
<td class="org-left">the lines without the <code>:</code></td>
</tr>

<tr>
<td class="org-left">a LaTeX fragment <code>$x$</code>, <code>\(x\)</code>, <code>\[x\]</code></td>
<td class="org-left">the formula (filetype <code>plaintex</code>)</td>
</tr>

<tr>
<td class="org-left">a <code>\begin{env}</code> &hellip; <code>\end{env}</code></td>
<td class="org-left">the environment</td>
</tr>

<tr>
<td class="org-left">a footnote reference <code>[fn:label]</code></td>
<td class="org-left">the definition of that footnote</td>
</tr>

<tr>
<td class="org-left"><code>#+INCLUDE:</code>, <code>#+SETUPFILE:</code></td>
<td class="org-left">visits the file</td>
</tr>

<tr>
<td class="org-left">a <code>SCHEDULED:</code> / <code>DEADLINE:</code> line</td>
<td class="org-left">runs <code>&lt;prefix&gt;s</code> / <code>&lt;prefix&gt;d</code></td>
</tr>

<tr>
<td class="org-left">a timestamp</td>
<td class="org-left">the date prompt</td>
</tr>

<tr>
<td class="org-left">a link</td>
<td class="org-left">follows it</td>
</tr>
</tbody>
</table>

Anywhere else it says "No special environment to edit here".

If the file changed under an open edit buffer, `:w` refuses to overwrite
the conflicting region; look at both versions and use `:w!` to force it.


<a id="orgc0d11a5"></a>

## Examples to edit

**Try:** put the cursor on `print` below and press `<prefix>'`.
**Expect:** a window with one line, `print("from the edit buffer")`, and
`:set ft?` says `filetype=lua`. Change the text, press `<prefix>'`: the
block below shows your change.

    print("from the edit buffer")

**Try:** `<prefix>'` on the first line of the fixed-width area below.
**Expect:** the edit buffer shows `first line` and `second line` without
the `:` markers. Add a third line, press `<prefix>'`: it comes back as
`: third line`.

    first line
    second line

**Try:** `<prefix>'` with the cursor inside the `$...$` formula below.
**Expect:** a buffer with only `a^2 + b^2 = c^2`.

Pythagoras: $a^2 + b^2 = c^2$ for a right triangle.

**Try:** `<prefix>'` on the environment below.
**Expect:** the whole `\begin{align}` &hellip; `\end{align}`, filetype
`plaintex`.

\begin{align}
e^{i\pi} + 1 &= 0
\end{align}

**Try:** `<prefix>'` on the inline block in this line: `echo inline`.
**Expect:** a buffer with `echo inline`, filetype `sh`.

**Try:** `<prefix>'` on `[fn:extras1]` in this sentence<sup><a id="fnr.extras1" class="footref" href="#fn.extras1" role="doc-backlink">1</a></sup>.
**Expect:** a buffer with the text of the definition just below. Edit it
and press `<prefix>'` to put it back.

    An example block: <prefix>' opens it too.


<a id="org73cb48e"></a>

## Narrowing is the same idea

`<prefix>hn` edits the current subtree in a separate buffer, `<prefix>nb`
the block at the cursor and `<prefix>ne` the element at the cursor
(Emacs `C-x n s`, `C-x n b`, `C-x n e`, which are taken by Vim keys
here). `:w` writes back, `<C-c>'` saves and closes. See
[01-outline](01-outline.md).


<a id="org29e3bf9"></a>

# Elements: paragraphs, lists, blocks, tables &hellip;

Org calls the parts of an entry's text *elements*: paragraphs, plain
lists and their items, blocks, drawers, tables, fixed-width areas,
keywords and comments. The blank lines after an element belong to it.
Some commands work on whole elements, like Emacs' `M-}`, `M-h`, `C-M-t`:

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Key</th>
<th scope="col" class="org-left">Emacs</th>
<th scope="col" class="org-left">What it does</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>&lt;M-}&gt;</code></td>
<td class="org-left"><code>M-}</code></td>
<td class="org-left">next element at the same level</td>
</tr>

<tr>
<td class="org-left"><code>&lt;M-{&gt;</code></td>
<td class="org-left"><code>M-{</code></td>
<td class="org-left">previous element</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-c&gt;&lt;C-^&gt;</code></td>
<td class="org-left"><code>C-c C-^</code></td>
<td class="org-left">up to the parent element</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-c&gt;&lt;C-_&gt;</code></td>
<td class="org-left"><code>C-c C-_</code></td>
<td class="org-left">into the first element inside</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;v</code></td>
<td class="org-left"><code>M-h</code></td>
<td class="org-left">select it; again adds the next</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-M-t&gt;</code></td>
<td class="org-left"><code>C-M-t</code></td>
<td class="org-left">swap with the previous one</td>
</tr>

<tr>
<td class="org-left"><code>&lt;M-k&gt;</code> <code>&lt;M-j&gt;</code></td>
<td class="org-left"><code>M-up</code> <code>M-down</code></td>
<td class="org-left">on text: drag it up / down</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-c&gt;&lt;M-f&gt;</code></td>
<td class="org-left"><code>C-c M-f</code></td>
<td class="org-left">next block (<code>&lt;C-c&gt;&lt;M-b&gt;</code> prev)</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-c&gt;:</code></td>
<td class="org-left"><code>C-c :</code></td>
<td class="org-left">toggle <code>:</code> fixed-width</td>
</tr>
</tbody>
</table>

Emacs' `M-h` is `<M-h>` (promote) in org.nvim, so select is `<prefix>v`.
The commands always act on whole lines.


<a id="org26715ee"></a>

## Practice

**Try:** put the cursor on "First paragraph" and press `<M-}>` four times.
**Expect:** the cursor visits "- a list item", "- another item" (inside a
list it moves from item to item), the table, and "Last paragraph", in
that order. `<M-{>` goes back the same way.

First paragraph. It is one element even though
it spans two lines.

-   a list item
-   another item

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-right" />
</colgroup>
<tbody>
<tr>
<td class="org-left">a table</td>
<td class="org-right">1</td>
</tr>
</tbody>
</table>

Last paragraph.

**Try:** on "Last paragraph" press `<C-M-t>`.
**Expect:** "Last paragraph." and the table swap places, and the cursor is
after both. `u` to undo.

**Try:** on "First paragraph" press `<prefix>v`, then `<prefix>v` again.
**Expect:** Visual line mode with the two lines of the paragraph and the
blank line after it selected; the second `<prefix>v` adds the next
element, "- a list item".

**Try:** select the two lines of "Some output" below with `Vj` and press
`<C-c>:`.
**Expect:** both lines start with `:` and a space (fixed-width, shown verbatim and
exported as code). `<C-c>:` again removes the markers.

Some output
of a command


<a id="orgd57504c"></a>

# Speed keys

Speed keys (Emacs `org-use-speed-commands`) are single letters that run a
command when you type them *at the very start of a headline*, before the
first star. Anywhere else the letter is inserted as usual. They are off by
default.

In org.nvim they work in **Insert mode**, with the cursor in column 0 of a
headline (in Normal mode those letters are Vim commands). So `I` (or `0i`)
on a headline, then letters. After each command the cursor goes back to
column 0 of the headline it ends on, still in Insert mode, so you can
type several in a row. `<Esc>` leaves.

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Key</th>
<th scope="col" class="org-left">Command</th>
<th scope="col" class="org-left">Key</th>
<th scope="col" class="org-left">Command</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>n</code> / <code>p</code></td>
<td class="org-left">next / previous heading</td>
<td class="org-left"><code>t</code></td>
<td class="org-left">change TODO state</td>
</tr>

<tr>
<td class="org-left"><code>f</code> / <code>b</code></td>
<td class="org-left">next / previous sibling</td>
<td class="org-left"><code>,</code></td>
<td class="org-left">set priority</td>
</tr>

<tr>
<td class="org-left"><code>u</code></td>
<td class="org-left">parent heading</td>
<td class="org-left"><code>0</code> to <code>3</code></td>
<td class="org-left">priority none, A, B, C</td>
</tr>

<tr>
<td class="org-left"><code>F</code> / <code>B</code></td>
<td class="org-left">next / previous block</td>
<td class="org-left"><code>:</code></td>
<td class="org-left">set tags</td>
</tr>

<tr>
<td class="org-left"><code>j</code></td>
<td class="org-left">go to a heading</td>
<td class="org-left"><code>e</code> <code>E</code></td>
<td class="org-left">set effort / next effort</td>
</tr>

<tr>
<td class="org-left"><code>g</code></td>
<td class="org-left">go to a refile target</td>
<td class="org-left"><code>W</code></td>
<td class="org-left">set <code>APPT_WARNTIME</code></td>
</tr>

<tr>
<td class="org-left"><code>c</code> / <code>C</code></td>
<td class="org-left">cycle / global cycle</td>
<td class="org-left"><code>I</code> <code>O</code></td>
<td class="org-left">clock in / out</td>
</tr>

<tr>
<td class="org-left"><code>SPC</code></td>
<td class="org-left">show the outline path</td>
<td class="org-left"><code>v</code></td>
<td class="org-left">agenda</td>
</tr>

<tr>
<td class="org-left"><code>s</code></td>
<td class="org-left">narrow to the subtree</td>
<td class="org-left"><code>/</code></td>
<td class="org-left">sparse tree</td>
</tr>

<tr>
<td class="org-left"><code>k</code></td>
<td class="org-left">cut the subtree</td>
<td class="org-left"><code>o</code></td>
<td class="org-left">open a link</td>
</tr>

<tr>
<td class="org-left"><code>=</code></td>
<td class="org-left">column view</td>
<td class="org-left"><code>&lt;</code> <code>&gt;</code></td>
<td class="org-left">agenda restriction lock</td>
</tr>

<tr>
<td class="org-left"><code>U</code> / <code>D</code></td>
<td class="org-left">move subtree up / down</td>
<td class="org-left"><code>i</code></td>
<td class="org-left">insert a heading</td>
</tr>

<tr>
<td class="org-left"><code>r</code> / <code>l</code></td>
<td class="org-left">demote / promote</td>
<td class="org-left"><code>^</code></td>
<td class="org-left">sort children</td>
</tr>

<tr>
<td class="org-left"><code>R</code> / <code>L</code></td>
<td class="org-left">the same with children</td>
<td class="org-left"><code>w</code></td>
<td class="org-left">refile</td>
</tr>

<tr>
<td class="org-left"><code>a</code></td>
<td class="org-left">archive subtree</td>
<td class="org-left"><code>@</code></td>
<td class="org-left">select the subtree</td>
</tr>

<tr>
<td class="org-left"><code>#</code></td>
<td class="org-left">toggle COMMENT</td>
<td class="org-left"><code>?</code></td>
<td class="org-left">list the speed keys</td>
</tr>
</tbody>
</table>

Turn them on in your config with `use_speed_commands = true`, and add or
change keys with `speed_commands`:

    require("org").setup({
      use_speed_commands = true,
      -- an action name, a function, or false to drop a key:
      speed_commands = { x = "archive_subtree", n = false },
    })

`use_speed_commands` may also be a function that returns true where speed
keys should apply.


<a id="org0c92d11"></a>

## Practice

**Try:** turn speed keys on for this session:

    :lua require("org.config").opts.use_speed_commands = true

Then put the cursor on "Speed one" below and press `0i` (column 0, Insert
mode). Type `n`, `n`, `p`.
**Expect:** the cursor moves to "Speed two", then "Speed three", then back
to "Speed two", staying in Insert mode in column 0. Nothing is inserted.

**Try:** still in Insert mode on "Speed two", type `D`.
**Expect:** "Speed two" moves below "Speed three": the order is one,
three, two.

**Try:** type `r`, then `l`.
**Expect:** "Speed two" gets one more star (a child of "Speed three"),
then `l` takes it away again.

**Try:** type `SPC` (the space bar).
**Expect:** the echo area shows the outline path, e.g.
`Speed keys/Practice/Speed two`.

**Try:** type `?`.
**Expect:** a window listing every speed key by group ("Outline
Navigation", "Outline Visibility" &hellip;). `q` closes it.

**Try:** press `<Esc>`, then `A` at the end of a headline and type `n`.
**Expect:** a plain `n` is inserted: speed keys only work in column 0.


<a id="orgb08c2e4"></a>

### Speed one


<a id="orge6bfee2"></a>

### Speed two


<a id="org45cb940"></a>

### Speed three


<a id="org14f7a8f"></a>

# Inline tasks

An inline task (the Emacs org-inlinetask module) is a TODO item in the
*middle* of an entry's text, which does not start a new entry: the text
after it still belongs to the entry above. It is a headline with at least
`inlinetask_min_level` stars (Emacs uses 15), optionally closed by a line
with the same stars and `END`:

    * Meeting notes
    We discussed the budget.
    *************** TODO Send the slides to Ana
    Details of the task can go here.
    *************** END
    And the notes continue: this line is still part of "Meeting notes".

Inline tasks are **off** by default, as in Emacs without the module
(`inlinetask_min_level = false`). While they are off, a line of 15 stars
is simply a very deep headline. When they are on:

-   they don't count as entries: folding, motions, `ar` and the agenda see
    the text around them as part of the entry above,
-   `<Tab>` on one folds it up to its `END` line,
-   `<<` / `>>` promote and demote the task and its `END` line together,
    never below the minimum level,
-   only their last two stars are shown,
-   `<C-c><C-x>t` (org-inlinetask-insert-task) inserts one below the
    cursor, or around the Visual selection. It gets
    `inlinetask_default_state` as keyword unless you give a count.
-   export writes them as a small box (`export.with_inlinetasks`).


<a id="orgb6725e2"></a>

## Practice

**Try:** turn inline tasks on:

    :lua require("org.config").opts.inlinetask_min_level = 15

then reload the file so it is parsed again: `:w` and `:e`.
Open this section again and press `<Tab>` on the line "TODO Call the
plumber" (the one with 15 stars).
**Expect:** before, that line was a headline of its own. Now `<Tab>` folds
the task down to one line (its details and `END` line hidden), and the
line shows only two stars.

**Try:** put the cursor on "More text of the entry" and press `<C-c><C-x>t`.
**Expect:** two lines of 15 stars are added below it, the second one
followed by `END`, and you are in Insert mode after the stars of the
first one. Type `TODO Buy milk` and `<Esc>`.

**Try:** on "Kitchen" below, press `ar` in Visual mode (`v a r`).
**Expect:** the selection covers "Kitchen" down to "Last line of the
entry", inline task included: it is not a subtree of its own.


<a id="org4dafb16"></a>

### Kitchen

The sink leaks.

<div class="inlinetask">
<b><span class="todo TODO">TODO</span> Call the plumber</b><br />
<p>
Ask for Tuesday morning.
</p>
</div>

More text of the entry.
Last line of the entry.


<a id="org6063be0"></a>

# Encryption: org-crypt

org-crypt encrypts the text of an entry with GnuPG, in the same format as
Emacs, so files encrypted in one editor decrypt in the other. It needs the
`gpg` program (`crypt.gpg_program`) installed and working; `gpg --version`
in a shell tells you.

-   Entries tagged `:crypt:` (`crypt.tag_matcher`, a match expression) are
    the ones the "entries" commands and encrypt-on-save act on.
-   The headline, the planning line, the property drawer, clock lines and
    the LOGBOOK stay readable. The rest of the entry, children included,
    becomes a `-----BEGIN PGP MESSAGE-----` block.
-   The key: the `CRYPTKEY` property, else `crypt.key`, is looked up in your
    public keyring. When nothing matches (`crypt.key` is `""` by default,
    which never matches) the entry is encrypted **symmetrically**, with a
    passphrase you type. `crypt.key = false` always encrypts
    symmetrically.
-   Passphrases are read with `inputsecret()` (twice when encrypting) and
    handed to gpg with `--pinentry-mode loopback`.

There are no default keys, as in Emacs. Use the commands (Emacs
`M-x org-encrypt-entry` and friends), or map the actions yourself:

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Command</th>
<th scope="col" class="org-left">What it does</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>:Org crypt_encrypt_entry</code></td>
<td class="org-left">encrypt the entry at the cursor</td>
</tr>

<tr>
<td class="org-left"><code>:Org crypt_decrypt_entry</code></td>
<td class="org-left">decrypt it</td>
</tr>

<tr>
<td class="org-left"><code>:Org crypt_encrypt_entries</code></td>
<td class="org-left">encrypt every <code>:crypt:</code> entry</td>
</tr>

<tr>
<td class="org-left"><code>:Org crypt_decrypt_entries</code></td>
<td class="org-left">decrypt them all</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-c&gt;&lt;C-r&gt;</code> (<code>:Org reveal</code>)</td>
<td class="org-left">decrypts the entry first</td>
</tr>
</tbody>
</table>

    require("org").setup({
      crypt = { key = "you@example.com", encrypt_on_save = true },
      -- keep the tag on the entries that carry it, as Emacs recommends:
      tags_exclude_from_inheritance = { "crypt" },
      mappings = { org = {
        crypt_encrypt_entry = "<prefix>xc",
        crypt_decrypt_entry = "<prefix>xC",
      } },
    })

With `crypt.encrypt_on_save = true`, the `:crypt:` entries are encrypted
before every write, and stay encrypted in the buffer afterwards (decrypt
again to keep working), like Emacs' `org-crypt-use-before-save-magic`.

**Leaks.** Decrypted text can reach the disk through the swap file and a
persistent undo file. Before decrypting in a buffer with either,
`crypt.disable_auto_save` (`"ask"` by default) asks whether to turn them
off for that buffer. `examples/minimal_init.lua` already sets
`noswapfile`, so you won't be asked here. Yanked text goes to registers,
which `shada` may save: see `:h org-crypt-leaks`.


<a id="orgfd896ea"></a>

## Practice

**Try:** put the cursor on "Wifi password" below and run
`:Org crypt_encrypt_entry`. Type a passphrase (`test` will do) and
`<CR>`, then the same again to confirm.
**Expect:** the message "No crypt key set, using symmetric encryption.",
and the two lines of text are replaced by a block like:

    -----BEGIN PGP MESSAGE-----
    
    jA0ECQMI...
    -----END PGP MESSAGE-----

The headline and its tag stay as they are. The letters differ every time.

**Try:** on the same headline run `:Org crypt_decrypt_entry` and type the
passphrase.
**Expect:** the original two lines are back.

**Try:** encrypt it again, then press `<C-c><C-r>` (reveal) on the headline.
**Expect:** you are asked for the passphrase and the text is decrypted:
revealing an encrypted entry decrypts it, as in Emacs.


<a id="org9c43852"></a>

### Wifi password     :crypt:

The network is "garden", the password is correct-horse-battery.
This line is encrypted too.


<a id="org0f736aa"></a>

# Display options

These options change how the buffer looks, not the file. Most have a
`#+STARTUP:` word for one file and a `ui` option for all files. See
[02-markup](02-markup.md) for emphasis and entities, and
[21-images-latex](21-images-latex.md) for images and formulas.

Options under `ui` in your setup:

-   **`num`:** number headlines: `1`, `1.1`, `1.2` &hellip;
    (`#+STARTUP:` `num` / `nonum`; toggle: `:Org num_mode`)
-   **`indent_mode`:** indent text under its headline (org-indent-mode)
    (`#+STARTUP:` `indent` / `noindent`)
-   **`hide_leading_stars`:** show only the last star
    (`#+STARTUP:` `hidestars` / `showstars`)
-   **`pretty_entities`:** `\alpha` shows as α, `x^2` as x²
    (`#+STARTUP:` `entitiespretty` / `entitiesplain`; toggle: `<C-c><C-x>\`)
-   **`conceal_links`:** show only link descriptions
    (toggle: `<prefix>lt`)
-   **`hide_emphasis_markers`:** hide the `*` `/` `_` &hellip; markers
-   **`bullets`:** symbols in place of the stars
-   **`checkboxes`:** icons for `[ ]` `[-]` `[X]`
-   **`todo_keyword_faces`, `priority_faces`, `tag_faces`:** colours per keyword /
    priority / tag

`examples/minimal_init.lua` sets `bullets` (◉ ○ ✸ ✿) and `checkboxes`,
which is why the stars of this file look the way they do.

Headline numbering follows the org-num options: `num_max_level`,
`num_skip_commented`, `num_skip_tags`, `num_skip_unnumbered` (a subtree
with an `UNNUMBERED` property) and `num_format_function`.

**Try:** `:Org num_mode`, then `<S-Tab>` until you see every headline.
**Expect:** "Org-Num mode enabled", and the headlines of this file are
numbered: "How to use this file" is `1`, its child "Keys in this file" is
`1.1`, "Getting help inside Neovim" is `2` and so on. `:Org num_mode`
again removes the numbers.

**Try:** change the `#+STARTUP:` line at the top of this file to
`#+STARTUP: overview indent`, press `<C-c><C-c>` on it and reload with
`:e`.
**Expect:** the body text of each entry is indented under its headline
(only on screen: the file is unchanged) and only one star of each
headline shows. Put the line back afterwards.

**Try:** press `<C-c><C-x>\` on this line: &alpha; &rarr; &beta;, E = mc<sup>2</sup>.
**Expect:** with pretty entities on you see α → β and mc². Press it again
to see the text as written.

Highlight groups (`OrgTodo`, `OrgTags`, `OrgLink`, `OrgHeadlineLevel1`
&hellip;) are listed in `:h org-highlights`; set them with `nvim_set_hl()`.


<a id="orgd22997b"></a>

# Setup files: #+SETUPFILE

Several files can share their settings (`#+TODO:`, `#+TAGS:`, `#+LINK:`,
`#+PROPERTY:`, `#+OPTIONS:` &hellip;) through a setup file:

    #+SETUPFILE: "~/org/setup/common.org"

Only the settings of that file are imported, never its headings. Paths
are relative to the file that names them; quotes allow spaces; setup
files may name other setup files (cycles are stopped). `<prefix>'` on
the line visits the file.

**Try:** add this line at the top of this file, below `#+TAGS:`, and press
`<C-c><C-c>` on it:

    #+SETUPFILE: tutorial.org

Then put the cursor on any headline of this file and press `<prefix>S`.
**Expect:** the TODO keyword menu now offers `TODO`, `NEXT`, `WAITING`,
`DONE` and `CANCELLED`: the `#+TODO:` line of [tutorial.org](tutorial.md)
was imported. Press `<Esc>`, delete the line again and press
`<C-c><C-c>` on the `#+TAGS:` line to refresh.

A missing setup file is ignored when the file is read; `:Org lint`
reports it (see the next section).


<a id="extras-lint"></a>

# org-lint: check the syntax

`:Org lint` (Emacs `M-x org-lint`) looks for mistakes that make Org read
your text differently from what you meant: a link to a heading that
doesn't exist, a footnote without its definition, a `#+begin_src` without
a language, a misspelt header argument &hellip; It lists what it finds in the
**location list** (`:lopen`), titled "org-lint". Each entry is
`checker: message`; `E` marks the reliable checks ("high trust"), `W` the
heuristics ("low trust"). It has no default key, as in Emacs.

-   `:Org lint` runs every checker.
-   `:Org lint duplicate-name invalid-fuzzy-link` runs only those
    (`<Tab>` completes the checker names), like Emacs' `C-u C-u M-x
      org-lint`.
-   `:lnext` / `:lprev` (or `]l` / `[l` in Neovim 0.11+) walk the list.
-   From Lua: `require("org.lint").lint(0)` returns the reports as a list
    of `{ lnum, col, checker, message, trust }`.

Every checker of Org 9.8 is implemented; `:h org-lint` lists them.

The rest of this file is clean. The subtree below is full of mistakes on
purpose. It is marked `COMMENT`, so it is never exported and the agenda
ignores its TODO entries and dates, but `org-lint` still checks it.

**Try:** run `:Org lint`, then `:lopen`.
**Expect:** 28 entries, all in "COMMENT Lint playground", in the order of
the list below. `<CR>` on an entry jumps to its line.

**Try:** `:Org lint duplicate-name`.
**Expect:** exactly two entries, `duplicate-name: Duplicate NAME "twice"`,
on the two `#+NAME: twice` lines.

**Try:** fix one mistake (for example add `sh` after the bare
`#+begin_src`), run `:Org lint` again.
**Expect:** that entry is gone and the others remain.

Each mistake of the playground and the entry it produces, in file order:

-   **two headings with `CUSTOM_ID: same-id`:** `duplicate-custom-id: Duplicate CUSTOM_ID property "same-id"` (twice)
-   **`[[*No such heading]]`:** `invalid-fuzzy-link: Unknown fuzzy location "No such heading"`
-   **`[[#no-such-id]]`:** `invalid-custom-id-link: Unknown custom ID "no-such-id"`
-   **`[[id:...]]` to an unknown ID:** `invalid-id-link: Unknown ID "00000000-..."`
-   **`[[file:does-not-exist.org]]`:** `link-to-local-file: Link to non-existent local file "does-not-exist.org"`
-   **a link followed by a stray `]`:** `trailing-bracket-after-link: Trailing ']' after link end`
-   **`#+begin_src` with no language:** `missing-language-in-src-block: Missing language in source block`
-   **`:foo bar` on a src block:** `wrong-header-argument: Unknown header argument ":foo"`
-   **`:results maybe`:** `wrong-header-value: Unknown value "maybe" for header ":results"`
-   **`#+TBLNAME:`:** `obsolete-affiliated-keywords: Obsolete affiliated keyword: "TBLNAME".  Use "NAME" instead`
-   **`#+BEGIN_HTML` block:** `deprecated-export-blocks: Deprecated syntax for export block.  Use "BEGIN_EXPORT HTML" instead`
-   **`#+NAME:` with nothing after it:** `orphaned-affiliated-keywords: Orphaned affiliated keyword: "NAME"`
-   **`[fn:nodef]` without a definition:** `undefined-footnote-reference: Missing definition for footnote [nodef]`
-   **`[fn:unused]` definition, no reference:** `unreferenced-footnote-definition: No reference for footnote definition [unused]`
-   **`:EFFORT: lots`:** `invalid-effort-property: Invalid effort duration format: "lots"`
-   **`:TODO:` in a property drawer:** `special-property-in-properties-drawer: Special property "TODO" found in a properties drawer`
-   **`SCHEDULED:` after body text:** `misplaced-planning-info: Misplaced planning info line`
-   **`SCHEDULED: [inactive date]`:** `planning-inactive: Inactive timestamp in SCHEDULED will not appear in agenda.`
-   **`<2026-12-03 Fri>` (it's a Thursday):** `timestamp-syntax: Potentially malformed timestamp <2026-12-03 Fri>.  Parsed as: <2026-12-03 Thu>`
-   **`[#Z]`:** `priority: Out-of-bounds priority 'Z'`
-   **a list numbered 1., 3.:** `item-number: Bullet counter "3. " is not the same with item position 2.  Consider adding manual [@3] counter.`
-   **tags `::work::`:** `spurious-colons: Tags contain a spurious colon`
-   **two `#+NAME: twice`:** `duplicate-name: Duplicate NAME "twice"` (twice)
-   **`#+ATTR_HTML :width 10` (no colon):** `invalid-keyword-syntax: Possible missing colon in keyword "ATTR_HTML"`
-   **`#+SETUPFILE: no-such-setup.org`:** `non-existent-setupfile-parameter: Non-existent setup file "no-such-setup.org"`
-   **`#+begin_quote` never closed:** `invalid-block: Possible incomplete block "#+begin_quote"`


<a id="orge018dd6"></a>

# Emacs keys

Coming from Emacs? Org's own keys (`org-mode-map`) work on top of the
Vim-style keys, so muscle memory keeps working. They live in three
sections of `mappings`, each of which can be turned off:

    require("org").setup({
      mappings = {
        emacs = false,        -- C-c ... keys in Normal mode
        emacs_insert = false, -- <C-CR>, <C-S-CR> in Insert mode
        emacs_global = false, -- <C-c>a agenda, <C-c>c capture, <C-c>l store link
      },
    })

-   `C-c` keys are Normal-mode only: in Insert mode `<C-c>` still leaves
    Insert mode.
-   Emacs' `C-u` prefix is a Vim count: `4<C-c>.` is `C-u C-c .`,
    `16<C-c><C-t>` is `C-u C-u C-c C-t`.
-   Keys marked "(ctx)" in `:h org-emacs-keys` depend on the cursor, like in
    Emacs: `<C-c>-` inserts a table rule in a table, cycles the bullet on a
    list item, and toggles an item elsewhere.
-   Emacs keys that Vim needs are moved: `M-h` (mark element) is
    `<prefix>v`, `C-x n s` / `C-x n b` (narrow) are `<prefix>hn` /
    `<prefix>nb`.

The Emacs key is typed as written, in Vim's key notation: `C-c C-t` is
`<C-c><C-t>`, `C-c .` is `<C-c>.`, `M-RET` is `<M-CR>`. The most used
ones and their Vim-style equivalents:

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Emacs</th>
<th scope="col" class="org-left">Vim-style key</th>
<th scope="col" class="org-left">Action</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>C-c C-c</code></td>
<td class="org-left"><code>&lt;prefix&gt;&lt;CR&gt;</code></td>
<td class="org-left">act on the context</td>
</tr>

<tr>
<td class="org-left"><code>C-c C-t</code></td>
<td class="org-left"><code>cit</code> / <code>&lt;prefix&gt;S</code></td>
<td class="org-left">change TODO state</td>
</tr>

<tr>
<td class="org-left"><code>C-c C-s</code> / <code>C-c C-d</code></td>
<td class="org-left"><code>&lt;prefix&gt;s</code> / <code>&lt;prefix&gt;d</code></td>
<td class="org-left">schedule / deadline</td>
</tr>

<tr>
<td class="org-left"><code>C-c .</code> / <code>C-c !</code></td>
<td class="org-left"><code>&lt;prefix&gt;i.</code> / <code>&lt;prefix&gt;i!</code></td>
<td class="org-left">timestamps</td>
</tr>

<tr>
<td class="org-left"><code>C-c C-q</code></td>
<td class="org-left"><code>&lt;prefix&gt;t</code></td>
<td class="org-left">set tags</td>
</tr>

<tr>
<td class="org-left"><code>C-c C-x p</code></td>
<td class="org-left"><code>&lt;prefix&gt;p</code></td>
<td class="org-left">set a property</td>
</tr>

<tr>
<td class="org-left"><code>C-c C-l</code></td>
<td class="org-left"><code>&lt;prefix&gt;li</code></td>
<td class="org-left">insert a link</td>
</tr>

<tr>
<td class="org-left"><code>C-c C-o</code></td>
<td class="org-left"><code>&lt;CR&gt;</code> / <code>gx</code></td>
<td class="org-left">open the link</td>
</tr>

<tr>
<td class="org-left"><code>C-c l</code></td>
<td class="org-left"><code>&lt;prefix&gt;ls</code></td>
<td class="org-left">store a link</td>
</tr>

<tr>
<td class="org-left"><code>C-c a</code> / <code>C-c c</code></td>
<td class="org-left"><code>&lt;prefix&gt;a</code> / <code>&lt;prefix&gt;c</code></td>
<td class="org-left">agenda / capture</td>
</tr>

<tr>
<td class="org-left"><code>C-c C-w</code></td>
<td class="org-left"><code>&lt;prefix&gt;r</code></td>
<td class="org-left">refile</td>
</tr>

<tr>
<td class="org-left"><code>C-c C-x C-i</code> / <code>C-o</code></td>
<td class="org-left"><code>&lt;prefix&gt;xi</code> / <code>&lt;prefix&gt;xo</code></td>
<td class="org-left">clock in / out</td>
</tr>

<tr>
<td class="org-left"><code>C-c C-e</code></td>
<td class="org-left"><code>&lt;prefix&gt;e</code></td>
<td class="org-left">export</td>
</tr>

<tr>
<td class="org-left"><code>C-c '</code></td>
<td class="org-left"><code>&lt;prefix&gt;'</code></td>
<td class="org-left">edit special</td>
</tr>

<tr>
<td class="org-left"><code>C-c C-x f</code></td>
<td class="org-left"><code>&lt;prefix&gt;if</code></td>
<td class="org-left">footnote</td>
</tr>

<tr>
<td class="org-left"><code>C-c C-,</code></td>
<td class="org-left"><code>&lt;prefix&gt;ib</code></td>
<td class="org-left">structure template</td>
</tr>

<tr>
<td class="org-left"><code>C-c /</code></td>
<td class="org-left"><code>&lt;prefix&gt;/</code></td>
<td class="org-left">sparse tree</td>
</tr>

<tr>
<td class="org-left"><code>C-c ;</code></td>
<td class="org-left"><code>&lt;prefix&gt;hC</code></td>
<td class="org-left">toggle COMMENT</td>
</tr>

<tr>
<td class="org-left"><code>C-c *</code> / <code>C-c -</code></td>
<td class="org-left"><code>&lt;prefix&gt;*</code> / <code>&lt;prefix&gt;-</code></td>
<td class="org-left">toggle heading / item</td>
</tr>

<tr>
<td class="org-left"><code>C-c C-r</code></td>
<td class="org-left">&nbsp;</td>
<td class="org-left">reveal the context</td>
</tr>

<tr>
<td class="org-left"><code>C-c C-v e</code></td>
<td class="org-left"><code>&lt;prefix&gt;be</code></td>
<td class="org-left">run a src block</td>
</tr>

<tr>
<td class="org-left"><code>M-RET</code></td>
<td class="org-left">&nbsp;</td>
<td class="org-left">new heading / item / row</td>
</tr>

<tr>
<td class="org-left"><code>C-RET</code></td>
<td class="org-left"><code>&lt;prefix&gt;ih</code></td>
<td class="org-left">heading after subtree</td>
</tr>
</tbody>
</table>

**Try:** on the headline "Emacs practice" below, press `<C-c><C-t>`.
**Expect:** it becomes "TODO Emacs practice" (this file has only
`TODO` and `DONE`, so the key cycles). Press `<C-c><C-t>` twice more to
get `DONE` and then no keyword.

**Try:** on the same headline press `<C-c>;`.
**Expect:** "COMMENT Emacs practice". Again to remove it.


<a id="org6669e35"></a>

### Emacs practice


<a id="org8bc0a05"></a>

# Integrations


<a id="org0373b60"></a>

## org-protocol: capture from the browser

`org-protocol://` URLs let a browser or another program talk to a
running Neovim, like Emacs' org-protocol:

-   **`org-protocol://capture?template=t&url=URL&title=TITLE&body=TEXT`:** capture with template `t`
-   **`org-protocol://store-link?url=URL&title=TITLE`:** store the link for `<prefix>li`
-   **`org-protocol://open-source?url=URL`:** open the local file of a published page

Neovim must listen on a socket (`nvim --listen ~/.cache/nvim/org.sock`),
and the operating system must hand `org-protocol:` URLs to a small
handler that calls:

    nvim --server ~/.cache/nvim/org.sock --remote-expr "v:lua.require'org.protocol'.handle('%u')"

`:h org-protocol` has the desktop file (Linux), the macOS app and a
bookmarklet. You can try it without any of that with `:Org protocol`:

**Try:** run

    :Org protocol org-protocol://store-link?url=https%3A%2F%2Forgmode.org&title=Org%20Mode

then on the empty line below press `<prefix>li`, `<CR>` at the "Insert
link (default <https://orgmode.org>)" prompt and `<CR>` again to accept the
description "Org Mode".
**Expect:** the message "insert<sub>link</sub> to insert new Org link, p to insert
"<https://orgmode.org>"", and the line becomes
`[[https://orgmode.org][Org Mode]]`.

**Try:** run

    :Org protocol org-protocol://capture?template=t&url=https%3A%2F%2Fneovim.io&title=Neovim

**Expect:** the capture window of the "Task" template of
`minimal_init.lua`, with a `[[https://neovim.io][Neovim]]` link in it.
`<C-c><C-k>` cancels.


<a id="org8185bc2"></a>

## RSS and Atom feeds

org-feed adds the items of RSS and Atom feeds as child headlines of an
inbox heading. List the feeds in your config:

    require("org").setup({
      feed = {
        feeds = {
          { name = "Neovim news", url = "https://neovim.io/news.xml",
            file = "~/org/feeds.org", headline = "Neovim news" },
        },
      },
    })

`<C-c><C-x>g` (`:Org feed_update_all`) fetches every feed with `curl`
and adds the new items; `<C-c><C-x>G` (`:Org feed_goto_inbox`) jumps to
an inbox. The items already seen are remembered in a `:FEEDSTATUS:`
drawer, in the format Emacs writes. See `:h org-feed`.


<a id="orgce04e31"></a>

## MobileOrg

`:Org mobile_push` copies your agenda files and agenda views into a
staging directory (`mobile.directory`) that a MobileOrg-style app syncs;
`:Org mobile_pull` brings back what you captured and edited on the phone.
See `:h org-mobile`.


<a id="org4cefeec"></a>

## The Lua API

`require("org")` has a small API for your own config and scripts
(`:h org-api`):

-   `require("org").agenda("a")` and `require("org").capture("t")` open a
    view or a template,
-   `require("org").action("cycle")` runs any action by name,
-   `require("org").statusline()` returns the running clock and timer as a
    string for your statusline, empty when nothing runs,
-   lower-level modules: `org.parser`, `org.files`, `org.date`,
    `org.agenda.search`, `org.export`, `org.dblock`.

Lua source blocks run inside Neovim, so you can try the API right here.

**Try:** press `<C-c><C-c>` in the block below and answer `y` when asked
"Evaluate this lua code block on your system?".
**Expect:** the `#+RESULTS:` under it is rewritten with the same value,
`<2026-10-05 Mon>`: one week after the date in the code. Change `1` to
`2` and run it again: `<2026-10-12 Mon>`.

    local date = require("org.date")
    return date.parse("<2026-09-28 Mon>"):add(1, "w"):to_string()

    <2026-10-05 Mon>


<a id="org2a5f35e"></a>

# Further reading

-   `:h org` the whole manual; `:h org-keymaps` every key; `:h org-commands`
    every `:Org` subcommand; `:h org-config` every option.
-   `:h org-completion`, `:h org-lint`, `:h org-speed-commands`,
    `:h org-inlinetask`, `:h org-crypt`, `:h org-crypt-leaks`.
-   `:h org-babel-edit-special` (special edit buffers), `:h org-elements`,
    `:h org-tempo`, `:h org-appearance`, `:h org-highlights`.
-   `:h org-setupfile`, `:h org-in-buffer-settings`.
-   `:h org-emacs-keys`, `:h org-differences`.
-   `:h org-protocol`, `:h org-feed`, `:h org-mobile`, `:h org-api`.
-   The other example files: [00-index](00-index.md).


# Footnotes

<sup><a id="fn.1" href="#fnr.1">1</a></sup> The definition of this footnote, edited from the reference.
