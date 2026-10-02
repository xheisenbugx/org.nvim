
# Table of Contents

1.  [How to use this file](#org2dc5823)
    1.  [How to check the result: export one subtree](#orgba55d0f)
    2.  [Keys in this file](#org9ceed55)
2.  [Emphasis](#orgb4ec9e4)
    1.  [Emphasis examples](#orgc60e13e)
    2.  [When emphasis does not work](#org27a19fc)
    3.  [Things that are not emphasis](#org28d6e92)
    4.  [Adding emphasis with a key](#org2fc59bc)
        1.  [Emphasize playground](#org9627784)
    5.  [Hiding the markers](#orge8718bb)
3.  [Subscripts and superscripts](#org14c171c)
    1.  [Scripts with defaults](#orgd1986c9)
    2.  [Scripts with braces only](#orgcda24b4)
4.  [Entities](#org42f874c)
    1.  [Entity examples](#org765f93b)
5.  [Special strings and smart quotes](#org22e105b)
    1.  [Dashes and dots](#org4f04a7e)
    2.  [Curly quotes](#org2ee9fa0)
6.  [LaTeX fragments](#org97668aa)
    1.  [Math examples](#org15303e2)
7.  [Paragraphs, line breaks and rules](#orgbc77e6e)
    1.  [Breaks and rules](#orgc8c3ec6)
8.  [Blocks](#org8f24d88)
    1.  [Block examples](#org302e170)
    2.  [Line numbers in examples](#org80a4529)
    3.  [Numbered example](#org73cb48e)
9.  [Fixed-width lines](#orgb08c2e4)
    1.  [Fixed-width playground](#org99967f4)
    2.  [Fixed-width example](#orgde2857d)
10. [Comments](#org1709cfb)
    1.  [Comment examples](#orgb0f1a4e)
11. [Keywords](#orgd5b1c41)
12. [Export snippets](#orgb6725e2)
    1.  [Snippet example](#org4dafb16)
13. [Macros](#orga5fd821)
    1.  [Macro examples](#org5befec0)
        1.  [Weekly meeting](#orgd279195)
14. [Further reading](#org925a93b)



<a id="org2dc5823"></a>

# How to use this file

This file shows how Org marks up text: emphasis, sub- and superscripts,
special symbols, blocks, comments, line breaks, keywords and macros. Most of
this markup is **shown** by the editor (colours, hidden markers) and **used**
by the exporter (HTML, LaTeX, plain text&hellip;).

Start Neovim from the root of the repository with the bundled config:

    nvim -u examples/minimal_init.lua examples/02-markup.org

-   The file opens folded. `<Tab>` on a heading opens it, `<S-Tab>` cycles
    the whole buffer.
-   `<prefix>` means `<leader>o` (`<Space>o` with the bundled config). `g?`
    lists every key of the buffer.
-   `u` undoes; `git checkout examples/02-markup.org` restores the file.
-   **Try:** lines are exercises, **Expect:** lines say what you should see.
-   Lines starting with =# = are comments: notes for you, never exported.


<a id="orgba55d0f"></a>

## How to check the result: export one subtree

Markup is easiest to verify by exporting. With the cursor anywhere inside a
heading, this command exports **only that subtree**, without the HTML page
around it, into a scratch buffer:

    :Org export html subtree body buffer

A split named "Org HTML Export" opens with the HTML. Close it with `:q`.
For a plain-text view use `utf8` instead of `html`. The same exports are in
the menu of `<prefix>e` (Emacs `<C-c><C-e>`): press `s` (subtree only) and
`b` (body only), then `h H` (HTML buffer) or `t U` (UTF-8 buffer). Export
itself is covered in [19-export.org](19-export.md).

Most **Expect:** lines below quote the exact HTML you should find.


<a id="org9ceed55"></a>

## Keys in this file

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Key</th>
<th scope="col" class="org-left">What it does</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>&lt;prefix&gt;E</code></td>
<td class="org-left">emphasize: wrap the selection in <code>*</code> <code>/</code> <code>_</code>&hellip;</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-c&gt;&lt;C-x&gt;&lt;C-f&gt;</code></td>
<td class="org-left">the same, Emacs key</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-c&gt;&lt;C-x&gt;\</code></td>
<td class="org-left">toggle pretty entities (<code>\alpha</code> shown as α)</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-c&gt;:</code></td>
<td class="org-left">toggle fixed-width =: = on the line / selection</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;ib</code></td>
<td class="org-left">insert a block (quote, example, src&hellip;)</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;hC</code></td>
<td class="org-left">toggle the COMMENT keyword of a headline</td>
</tr>

<tr>
<td class="org-left"><code>&lt;Tab&gt;</code></td>
<td class="org-left">on a <code>#+begin_</code> line: fold / unfold the block</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;e</code></td>
<td class="org-left">export menu</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;xl</code></td>
<td class="org-left">preview LaTeX fragments as images</td>
</tr>
</tbody>
</table>


<a id="orgb4ec9e4"></a>

# Emphasis

Six markers change how text looks. Put the marker right before the first
character and right after the last one:

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">You write</th>
<th scope="col" class="org-left">You get</th>
<th scope="col" class="org-left">HTML</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>*bold*</code></td>
<td class="org-left"><b>bold</b></td>
<td class="org-left"><code>&lt;b&gt;bold&lt;/b&gt;</code></td>
</tr>

<tr>
<td class="org-left"><code>/italic/</code></td>
<td class="org-left"><i>italic</i></td>
<td class="org-left"><code>&lt;i&gt;italic&lt;/i&gt;</code></td>
</tr>

<tr>
<td class="org-left"><code>_underlined_</code></td>
<td class="org-left"><span class="underline">underlined</span></td>
<td class="org-left"><code>&lt;span class</code>"underline"&gt;&hellip;=</td>
</tr>

<tr>
<td class="org-left"><code>+strike+</code></td>
<td class="org-left"><del>strike</del></td>
<td class="org-left"><code>&lt;del&gt;strike&lt;/del&gt;</code></td>
</tr>

<tr>
<td class="org-left"><code>=verbatim=</code></td>
<td class="org-left"><code>verbatim</code></td>
<td class="org-left"><code>&lt;code&gt;verbatim&lt;/code&gt;</code></td>
</tr>

<tr>
<td class="org-left"><code>~code~</code></td>
<td class="org-left"><code>code</code></td>
<td class="org-left"><code>&lt;code&gt;code&lt;/code&gt;</code></td>
</tr>
</tbody>
</table>

`verbatim` and `code` look the same in most exports; the difference is
that nothing inside them is interpreted: no emphasis, no links, no
entities. Use `code` for code and `verbatim` for keys, file names and
literal strings (this is the convention of the Org manual).

Emphasis can be nested, and can span **two** lines, but not more.

**Try:** open "Emphasis examples" below and look at the colours: each kind of
markup has its own highlight group (`OrgBold`, `OrgItalic`, `OrgUnderline`,
`OrgStrikethrough`, `OrgVerbatim`, `OrgCode`). Then, with the cursor in it,
run `:Org export html subtree body buffer`.

**Expect:** the HTML contains, one per line:

    <b>bold</b>, <i>italic</i>, <span class="underline">underlined</span>,
    <del>strike-through</del>, <code>verbatim</code> and <code>code</code>.
    <b>bold with <i>italic inside</i> it</b>
    <code>*not bold*</code>
    <b>emphasis over
    two lines</b>


<a id="orgc60e13e"></a>

## Emphasis examples

**bold**, *italic*, <span class="underline">underlined</span>,
<del>strike-through</del>, `verbatim` and `code`.
**bold with *italic inside* it**
`*not bold*` because verbatim shows its text as it is.
**emphasis over
two lines** works.


<a id="org27a19fc"></a>

## When emphasis does not work

The markers are only recognised in the right context (Org's
`org-emphasis-regexp-components`):

-   The opening marker must be at the start of a line or after a space or one
    of `-('"{`. The closing marker must be followed by a space, the end of the
    line, or one of `-.,:!?;'")}\[`. So markers inside a word do nothing:
    `a*b*c` stays as it is.
-   The text inside cannot start or end with a space: `* no *` is not bold.
-   Emphasis spans at most two lines. Three lines: no emphasis.
-   Inside `verbatim` and `code` nothing is interpreted.

**Try:** open "Things that are not emphasis" and export it as above.

**Expect:** none of these lines has `<b>`, `<i>` or `<del>` in the HTML:
the stars, slashes and plus signs come out as plain characters:

    a*b*c in the middle of a word.
    Here * no stars * because of the spaces inside.
    2+3+4 is just arithmetic.
    path/to/file is not italic.

(Underscores are different: `snake_case` gives a subscript, see the next
topic.)


<a id="org28d6e92"></a>

## Things that are not emphasis

a\*b\*c in the middle of a word.
Here \* no stars \* because of the spaces inside.
2+3+4 is just arithmetic.
path/to/file is not italic.


<a id="org2fc59bc"></a>

## Adding emphasis with a key

`<prefix>E` (Emacs `<C-c><C-x><C-f>`) asks for a marker (`*` `/` `_` `+`
`=` `~`) and:

-   in Visual mode, wraps the selection in it; if the selection already has a
    marker, it is replaced; answering `<Space>` removes the markers;
-   in Normal mode, inserts a pair of markers and puts you in Insert mode
    between them.

Spaces are added when needed so the markers are recognised.

**Try:** on the line "Make this word bold." below, put the cursor on "word",
press `viw`, then `<prefix>E` and `*`.

**Expect:** the line reads `Make this *word* bold.` and "word" turns bold.

**Try:** put the cursor on the first star of `*word*`, select up to the
second star with `vf*`, press `<prefix>E` and `/`.

**Expect:** the stars are replaced: `Make this /word/ bold.`

**Try:** on the line "Type between alpha beta", put the cursor on the `b` of
"beta", press `<prefix>E` and `~`, type `ls` and press `<Esc>`.

**Expect:** `Type between alpha ~ls~ beta`: the pair was inserted before
"beta" and a space was added after it, so the markers are recognised.


<a id="org9627784"></a>

### Emphasize playground

Make this word bold.
Type between alpha beta


<a id="orge8718bb"></a>

## Hiding the markers

With `ui.hide_emphasis_markers = true` the markers are concealed: you see
**bold** without its stars. The markers stay in the file, and show again on
the line under the cursor (depending on `'concealcursor'`).

**Try:** run these two commands, then look at "Emphasis examples":

    :lua require("org.config").opts.ui.hide_emphasis_markers = true
    :w | e

**Expect:** the markers disappear from lines away from the cursor. Set it
back to `false` the same way.


<a id="org14c171c"></a>

# Subscripts and superscripts

`_` makes a subscript and `^` a superscript: `x^2`, `a_i`. Without braces
the script extends over all the letters and digits that follow, so write
`H_{2}O` (not `H_2O`, which subscripts "2O"). Braces are always safe:
`x^{10}`, `a_{ij}`.

Two settings control them:

-   In the buffer, with `ui.pretty_entities` on (see Entities below), scripts
    are drawn with Unicode super/subscript characters when all of their
    characters have one (x², aᵢⱼ), else highlighted with `OrgSuperscript` /
    `OrgSubscript`.
-   In the export, `#+OPTIONS: ^:{}` (or `:EXPORT_OPTIONS: ^:{}` on a
    subtree) only accepts scripts in braces, so `snake_case` stays intact.
    `^:nil` turns them off.

**Try:** export "Scripts with defaults" (`:Org export html subtree body
buffer`).

**Expect:**

    H<sub>2</sub>O and E=mc<sup>2</sup> and a<sub>ij</sub>
    H<sub>2O</sub> is wrong: "2O" is subscripted.
    snake<sub>case</sub>

**Try:** export "Scripts with braces only" the same way.

**Expect:** `H_2O` and `snake_case` stay as they are, only the braced ones
change:

    H_2O snake_case x<sup>2</sup> a<sub>ij</sub>


<a id="orgd1986c9"></a>

## Scripts with defaults

H<sub>2</sub>O and E=mc<sup>2</sup> and a<sub>ij</sub>
H<sub>2O</sub> is wrong: "2O" is subscripted.
snake<sub>case</sub>


<a id="orgcda24b4"></a>

## Scripts with braces only

H<sub>2O</sub> snake<sub>case</sub> x<sup>2</sup> a<sub>ij</sub>


<a id="org42f874c"></a>

# Entities

Entities are TeX-like names for symbols: `\alpha`, `\to`, `\deg`,
`\copy`&hellip; Org knows hundreds of them (the same list as Emacs'
`org-entities`). Each exporter writes the right thing: `&alpha;` in HTML,
`\alpha` in LaTeX, `α` in UTF-8 text. End an entity with `{}` when a letter
follows: `\alpha{}beta`.

In the buffer, `ui.pretty_entities = true` (or `#+STARTUP: entitiespretty`)
shows them as their Unicode character. `<C-c><C-x>\` toggles this for the
current buffer. Entities are never prettified in blocks, code, verbatim or
links. As in Emacs, only entities with a one-character symbol are drawn:
`\sin` or `\lim` stay as written in the buffer (they still export as
`sin` and `lim`).

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Write</th>
<th scope="col" class="org-left">Shows as</th>
<th scope="col" class="org-left">Write</th>
<th scope="col" class="org-left">Shows as</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>\alpha</code></td>
<td class="org-left">α</td>
<td class="org-left"><code>\to</code></td>
<td class="org-left">→</td>
</tr>

<tr>
<td class="org-left"><code>\beta</code></td>
<td class="org-left">β</td>
<td class="org-left"><code>\larr</code></td>
<td class="org-left">←</td>
</tr>

<tr>
<td class="org-left"><code>\pi</code></td>
<td class="org-left">π</td>
<td class="org-left"><code>\deg</code></td>
<td class="org-left">°</td>
</tr>

<tr>
<td class="org-left"><code>\infty</code></td>
<td class="org-left">∞</td>
<td class="org-left"><code>\copy</code></td>
<td class="org-left">©</td>
</tr>

<tr>
<td class="org-left"><code>\pm</code></td>
<td class="org-left">±</td>
<td class="org-left"><code>\euro</code></td>
<td class="org-left">€</td>
</tr>

<tr>
<td class="org-left"><code>\times</code></td>
<td class="org-left">×</td>
<td class="org-left"><code>\nbsp</code></td>
<td class="org-left">(space)</td>
</tr>
</tbody>
</table>

**Try:** open "Entity examples" and press `<C-c><C-x>\`.

**Expect:** `\alpha` is drawn as α, `\to` as →, `\deg{}` as °, and the
scripts `x^2` and `a_{ij}` as x² and aᵢⱼ. Press `<C-c><C-x>\` again to see
the plain text.

**Try:** export "Entity examples" to HTML.

**Expect:**

    &alpha; &beta; &pi; &rarr; 20&deg;C &copy; 2026
    &alpha;beta (the {} ends the name)


<a id="org765f93b"></a>

## Entity examples

&alpha; &beta; &pi; &rarr; 20&deg;C &copy; 2026
&alpha;beta (the {} ends the name)
x<sup>2</sup> and a<sub>ij</sub>


<a id="org22e105b"></a>

# Special strings and smart quotes

When exporting, a few character sequences become typographic symbols
(`#+OPTIONS: -:t`, the default; `-:nil` turns it off):

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Write</th>
<th scope="col" class="org-left">Becomes</th>
<th scope="col" class="org-left">HTML</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>--</code></td>
<td class="org-left">en dash –</td>
<td class="org-left"><code>&amp;ndash;</code></td>
</tr>

<tr>
<td class="org-left"><code>---</code></td>
<td class="org-left">em dash —</td>
<td class="org-left"><code>&amp;mdash;</code></td>
</tr>

<tr>
<td class="org-left"><code>...</code></td>
<td class="org-left">ellipsis …</td>
<td class="org-left"><code>&amp;hellip;</code></td>
</tr>

<tr>
<td class="org-left"><code>\-</code></td>
<td class="org-left">soft hyphen</td>
<td class="org-left"><code>&amp;shy;</code></td>
</tr>
</tbody>
</table>

Smart quotes (`#+OPTIONS: ':t`, off by default) turn "straight" quotes
into curly ones, using the quotes of `#+LANGUAGE:`.

**Try:** export "Dashes and dots", then "Curly quotes".

**Expect:**

    pages 10&ndash;20 &mdash; and so on&hellip;

and for "Curly quotes":

    &ldquo;Hello,&rdquo; she said. It&rsquo;s fine.


<a id="org4f04a7e"></a>

## Dashes and dots

pages 10&ndash;20 &mdash; and so on&hellip;


<a id="org2ee9fa0"></a>

## Curly quotes

"Hello," she said. It's fine.


<a id="org97668aa"></a>

# LaTeX fragments

Math is written in LaTeX: `$x^2$` or `\(x^2\)` inline, `\[ ... \]` or
`\begin{equation}` &hellip; `\end{equation}` for displayed formulas. In the
buffer they are highlighted (`OrgLatex`); `<prefix>xl` (Emacs
`<C-c><C-x><C-l>`) previews them as images if you have LaTeX and an image
backend. HTML export uses MathJax. Details and previews:
[21-images-latex.org](21-images-latex.md).

`$` is only math when it is not next to a space inside: `$5 and $10` is
money, not math.

**Try:** export "Math examples".

**Expect:**

    The area is \(\pi r^2\) and \(a+b\).
    \[ E = mc^2 \]
    It costs $5 and $10.


<a id="org15303e2"></a>

## Math examples

The area is $\pi r^2$ and $a+b$.
$$ E = mc^2 $$
It costs $5 and $10.


<a id="orgbc77e6e"></a>

# Paragraphs, line breaks and rules

-   A **paragraph** is a group of lines; blank lines separate paragraphs. Line
    breaks inside a paragraph are ignored when exporting.
-   `\\` at the end of a line forces a line break.
-   `#+OPTIONS: \n:t` keeps every line break of the file.
-   A line of **five or more dashes** (`-----`) is a horizontal rule.

**Try:** export "Breaks and rules".

**Expect:** the first paragraph has no `<br />` (a browser shows its two
lines as one), the second has one after "Forced", and the dashes became
`<hr />`:

    <p>
    These two lines
    form one paragraph.
    </p>
    
    <p>
    Forced <br />
    break here.
    </p>
    
    <hr />


<a id="orgc8c3ec6"></a>

## Breaks and rules

These two lines
form one paragraph.

Forced   
break here.

---

A new paragraph after the rule.


<a id="org8f24d88"></a>

# Blocks

Blocks start with `#+begin_NAME` and end with `#+end_NAME` (upper or lower
case). Insert them with `<prefix>ib` (see
[01-outline.org](01-outline.md)). `<Tab>` on the `#+begin_` line
folds the block; `#+STARTUP: hideblocks` folds all of them when the file
opens.

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Block</th>
<th scope="col" class="org-left">Meaning</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>quote</code></td>
<td class="org-left">a quotation</td>
</tr>

<tr>
<td class="org-left"><code>center</code></td>
<td class="org-left">centered text</td>
</tr>

<tr>
<td class="org-left"><code>verse</code></td>
<td class="org-left">a poem: line breaks and indentation are kept</td>
</tr>

<tr>
<td class="org-left"><code>example</code></td>
<td class="org-left">verbatim text in a monospace font</td>
</tr>

<tr>
<td class="org-left"><code>src LANG</code></td>
<td class="org-left">source code in language LANG</td>
</tr>

<tr>
<td class="org-left"><code>export BACKEND</code></td>
<td class="org-left">raw text for one exporter only (<code>html</code>, <code>latex</code>&hellip;)</td>
</tr>

<tr>
<td class="org-left"><code>comment</code></td>
<td class="org-left">never exported</td>
</tr>
</tbody>
</table>

Markup works inside quote, center and verse blocks, but not inside example
and src blocks.

**Try:** on "Block examples", press `<Tab>` until everything shows, then
press `<Tab>` on each `#+begin_` line to fold and unfold it.

**Expect:** each block folds into its `#+begin_` line.

**Try:** export "Block examples".

**Expect:** in the HTML you find `<blockquote>` with `<b>ideas</b>` inside,
`<div class`"org-center">=, `<p class`"verse">= with `&nbsp;` for the
indentation and `<br />` at every line end, `<pre class`"example">= with
`*not bold*` left as it is, `<pre class`"src src-lua">=, the raw
`<em>raw HTML</em>`, and **no** trace of "This is a comment block".


<a id="org302e170"></a>

## Block examples

> Everything is made of **ideas**. &mdash; Anonymous

<div class="org-center">
<p>
Centered title
</p>
</div>

<p class="verse">
Roses are red,<br />
&nbsp;&nbsp;violets are blue,<br />
&nbsp;&nbsp;&nbsp;&nbsp;verses keep<br />
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;their indentation too.<br />
</p>

    Example text: *not bold*, shown exactly as typed.

    print("hello from Lua")

<em>raw HTML</em>


<a id="org80a4529"></a>

## Line numbers in examples

Example and src blocks accept switches. `-n` numbers the lines, `+n`
continues the numbering of the previous block.

**Try:** export "Numbered example".

**Expect:** the lines start with `<span class`"linenr">1: </span>= and
`<span class`"linenr">2: </span>=.


<a id="org73cb48e"></a>

## Numbered example

    1  first line
    2  second line


<a id="orgb08c2e4"></a>

# Fixed-width lines

A line starting with a colon and a space (=: =) is shown and exported
verbatim, like a one-line example block. Handy for short program output.

`<C-c>:` (`toggle_fixed_width`) adds or removes the =: = prefix on the
current line, or on every line of a Visual selection.

**Try:** select the two "output" lines below with `V` and `j`, press `<C-c>:`.

**Expect:** both lines start with `: = and are highlighted as fixed-width.
Select the two lines again (=V` and `j`) and press `<C-c>:` to remove it.

**Try:** export "Fixed-width example".

**Expect:**

    <pre class="example">
    $ date
    Mon Sep 28 10:00:00 2026
    </pre>


<a id="org99967f4"></a>

## Fixed-width playground

output line one
output line two


<a id="orgde2857d"></a>

## Fixed-width example

    $ date
    Mon Sep 28 10:00:00 2026


<a id="org1709cfb"></a>

# Comments

Three ways to keep text out of the export:

1.  A line starting with `#` followed by a space (or `#` alone) is a
    comment line. `#+` starts a keyword instead, and `#word` is plain text.
2.  A `#+begin_comment` / `#+end_comment` block (see Blocks).
3.  A headline starting with `COMMENT` comments out the whole subtree: it is
    left out of the export and the agenda. `<prefix>hC` (Emacs `<C-c>;`)
    toggles the keyword.

**Try:** export "Comment examples".

**Expect:** only "Visible text." and "#hashtag is not a comment." are in the
HTML. Nothing of "Secret child" appears.

**Try:** on "Secret child", press `<prefix>hC`, and export again.

**Expect:** the keyword is removed, and "Secret child" and "Its text." now
appear in the HTML.


<a id="orgb0f1a4e"></a>

## Comment examples

Visible text.

\#hashtag is not a comment.


<a id="orgd5b1c41"></a>

# Keywords

Lines like `#+TITLE: ...` are keywords: settings for the file or the
export. The ones at the top of this file are:

-   **`#+TITLE:` and `#+AUTHOR:`:** the document title and author.
-   **`#+STARTUP:`:** how the file opens (see
    [01-outline.org](01-outline.md)).
-   **`#+CATEGORY:`:** the name used by the agenda.
-   **`#+MACRO:`:** text macros (see Macros below).

Others you will meet: `#+OPTIONS:` (export options), `#+TODO:`,
`#+TAGS:`, `#+PROPERTY:`, `#+COLUMNS:`, and the **affiliated** keywords
`#+NAME:`, `#+CAPTION:` and `#+ATTR_HTML:` which go right above an element
(a table, a block, an image) to name or describe it. After editing a `#+`
line, press `<C-c><C-c>` on it so the buffer picks up the change.


<a id="orgb6725e2"></a>

# Export snippets

`@@BACKEND:text@@` inserts raw text for one exporter only, inline. Other
exporters drop it. Use it for things Org markup can't express, e.g.
keyboard keys in HTML.

**Try:** export "Snippet example" to HTML, then to UTF-8
(`:Org export utf8 subtree body buffer`).

**Expect:** in HTML: `Press <kbd>Ctrl</kbd>-<kbd>S</kbd> to save.` In UTF-8:
`Press Ctrl-S to save.`


<a id="org4dafb16"></a>

## Snippet example

Press <kbd>Ctrl</kbd>-<kbd>S</kbd> to save.


<a id="orga5fd821"></a>

# Macros

Macros are templates expanded when exporting: `#+MACRO: name text` defines
one, `{{{name(arg1,arg2)}}}` uses it. In the text, `$1`, `$2`&hellip; are the
arguments and `$0` all of them. A comma inside an argument is written
`\,`. This file defines three macros at the top:

    #+MACRO: greet Hello, $1!
    #+MACRO: swap $2 before $1
    #+MACRO: kbd @@html:<kbd>@@$1@@html:</kbd>@@

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
<td class="org-left">the <code>#+TITLE:</code></td>
</tr>

<tr>
<td class="org-left"><code>{{{author}}}</code></td>
<td class="org-left">the <code>#+AUTHOR:</code></td>
</tr>

<tr>
<td class="org-left"><code>{{{date(FMT)}}}</code></td>
<td class="org-left">the <code>#+DATE:</code>, formatted (FMT optional)</td>
</tr>

<tr>
<td class="org-left"><code>{{{time(FMT)}}}</code></td>
<td class="org-left">the export time, e.g. <code>%Y-%m-%d</code></td>
</tr>

<tr>
<td class="org-left"><code>{{{keyword(NAME)}}}</code></td>
<td class="org-left">the value of any <code>#+NAME:</code> keyword</td>
</tr>

<tr>
<td class="org-left"><code>{{{property(NAME)}}}</code></td>
<td class="org-left">a property of the entry around the macro</td>
</tr>

<tr>
<td class="org-left"><code>{{{n}}}</code></td>
<td class="org-left">a counter: 1, 2, 3&hellip; (<code>{{{n(name)}}}</code>)</td>
</tr>

<tr>
<td class="org-left"><code>{{{input-file}}}</code></td>
<td class="org-left">the name of this file</td>
</tr>

<tr>
<td class="org-left"><code>{{{modification-time(FMT)}}}</code></td>
<td class="org-left">when the file was last changed</td>
</tr>
</tbody>
</table>

In the buffer, macros are highlighted with `OrgMacro` and not expanded.

**Try:** export "Macro examples".

**Expect:** (the export also has a small table of contents, because of the
child headline)

    Hello, World! Hello, Ada, Grace!
    second before first
    Press <kbd>C-c</kbd>.
    Title: Markup: emphasis, blocks, comments and friends
    Author: Ada Lovelace
    Steps 1, 2, 3.

and under the "Weekly meeting" heading:

    Room: Blue room


<a id="org5befec0"></a>

## Macro examples

Hello, World! Hello, Ada, Grace!
second before first
Press <kbd>C-c</kbd>.
Title: Markup: emphasis, blocks, comments and friends
Author: Ada Lovelace
Steps 1, 2, 3.


<a id="orgd279195"></a>

### Weekly meeting

Room: Blue room


<a id="org925a93b"></a>

# Further reading

-   **`:h org-appearance`:** hiding markers, pretty entities, highlights
-   **`:h org-highlights`:** the highlight groups (`OrgBold`, `OrgLatex`&hellip;)
-   **`:h org-structure`:** `<prefix>E`, `<prefix>ib`, `<C-c>:`
-   **`:h org-export-settings`:** `#+OPTIONS:` keys and macros
-   **`:h org-images`:** LaTeX previews
-   [19-export.org](19-export.md) and
    [21-images-latex.org](21-images-latex.md) :: more on export and math

